#include "geom.h"
#include "bxdf_types.h"
#include "utils.cl"
#include "env_map.cl"

// Logic kernel
kernel void logic(
    global GPUTaskState *tasks,
    global float *pixels,
    global QueueCounters *queueLens,
    global uint *extQueue,
    global uint *shadowQueue,
    global uint *raygenQueue,
    global uint *diffuseQueue,
    global uint *glossyQueue,
    global uint *ggxReflQueue,
    global uint *ggxRefrQueue,
    global uint *deltaQueue,
    global Triangle *tris,
    global GPUNode *nodes,
    global uint *indices,
    read_only image2d_t envMap,
    global float *probTable,
    global int *aliasTable,
    global float *pdfTable,
    global Material *materials,
    global uchar *texData,
    global TexDescriptor *textures,
    global RenderParams *params,
    uint numTasks
)
{
    uint gid = get_global_id(0);

    if (gid >= numTasks)
        return;

    bool emitterHit = false;

    uint seed = ReadU32(seed, tasks);
    uint len = ReadU32(pathLen, tasks);
    
    Hit hit = readHitSoA(tasks, gid, numTasks);
    const float3 rayOrig = ReadFloat3(orig, tasks);
    const float3 rayDir = ReadFloat3(dir, tasks);
    Ray r = { rayOrig, rayDir };

    /*
    TODO: implicit hit checking could be a separate kernel
    */

    // NB:
    // LastLightPickProb happens to be correct, since it is the same for all light sources (or only belongs to a single source)
    // If light sources are non-uniformly sampled, the probability has to be queried per source, not per path

    // Implicit environment map sample
    if (hit.i < 0 && len > 0) // not before first raycast
    {
        float3 bg = (float3)(0.0f, 0.0f, 0.0f);
        if (params->useEnvMap && (len == 1 || params->sampleImpl))
            bg = evalEnvMapDir(envMap, r.dir) * params->envMapStrength;
        
        // MIS
        float weight = 1.0f;
        bool lastSpecular = ReadU32(lastSpecular, tasks);
        if (params->sampleImpl && params->sampleExpl && params->useEnvMap && len > 1 && !lastSpecular)
        {
            const float lightPickProb = ReadF32(lastLightPickProb, tasks);
            int2 dims = get_image_dim(envMap);
            float directPdfW = envMapPdf(dims.x, dims.y, pdfTable, rayDir);
            float actualPdfW = ReadF32(lastPdfW, tasks);
            weight = (actualPdfW * lightPickProb) / (actualPdfW * lightPickProb + directPdfW);
        }   

        float3 T = ReadFloat3(T, tasks);
		float3 newEi = ReadFloat3(Ei, tasks) + weight * T * bg;
		WriteFloat3(Ei, tasks, newEi);
		emitterHit = true;
    }
    // Implicit area light sample
    else if (hit.areaLightHit)
    {
		float misWeight = 1.0f;
		bool lastSpecular = ReadU32(lastSpecular, tasks);
		if (params->sampleExpl && len > 1 && !lastSpecular) // not very direct + MIS needed
		{
			const float directPdfA = 1.0f / (4.0f * params->areaLight.size.x * params->areaLight.size.y);
			const float directPdfW = pdfAtoW(directPdfA, length(hit.P - r.orig), dot(normalize(-r.dir), hit.N)); // normal of light
			const float lightPickProb = ReadF32(lastLightPickProb, tasks);
			const float lastPdfW = ReadF32(lastPdfW, tasks);
			misWeight = lastPdfW / (lastPdfW + directPdfW * lightPickProb);
		}

		// Pdf (i.e. extension ray pdf = lastPdfW) included in prob
		float3 T = ReadFloat3(T, tasks);
		float3 newEi = ReadFloat3(Ei, tasks) + T * misWeight * params->areaLight.E;
		WriteFloat3(Ei, tasks, newEi);
        
		// No reflective lights
        emitterHit = true;
    }

    // Explicit light sample (NEE), if non-occluded
    bool blocked = ReadU32(shadowRayBlocked, tasks);
    if (!blocked)
    {
        const float3 emission = ReadFloat3(lastEmission, tasks);
        const float3 bsdf = ReadFloat3(lastBsdf, tasks);
        const float cosTh = ReadF32(lastCosTh, tasks); // cos at surface
        const float directPdfW = ReadF32(lastPdfDirect, tasks);
        const float bsdfPdfW = ReadF32(lastPdfImplicit, tasks);
        const float lightPickProb = ReadF32(lastLightPickProb, tasks);

        // Only do MIS weighting if other samplers (bsdf-sampling) could have generated the sample
        float weight = 1.0f;
        if (params->sampleImpl)
        {
            weight = (directPdfW * lightPickProb) / (directPdfW * lightPickProb + bsdfPdfW);
        }

        const float3 T = ReadFloat3(lastT, tasks);
        const float3 contrib = bsdf * T * emission * weight * cosTh / (lightPickProb * directPdfW);
        const float3 newEi = ReadFloat3(Ei, tasks) + contrib;
        WriteFloat3(Ei, tasks, newEi);
    }

    float3 T = ReadFloat3(T, tasks);

    // Russian roulette
    float contProb = 1.0f;
	bool terminate = (len >= params->maxBounces + 1); // bounces = path_length - 1
    if (terminate && params->useRoulette)
    {
		contProb = clamp(luminance(T), 0.01f, 0.5f);
		terminate = (rand(&seed) > contProb);
    }

    // Compensate for RR
	T /= contProb;
    WriteFloat3(T, tasks, T);

    // Terminate if throughput is zero
	if (isZero(T) || ReadF32(lastPdfW, tasks) == 0.0f)
		terminate = true;

    // First iteration
    if (len == 0)
        terminate = true;

    // Image accumulation
	if (emitterHit || terminate)
    {
        if (len > 0)
        {
            uint pixIdx = ReadU32(pixelIndex, tasks);
            float4 color = (float4)(ReadFloat3(Ei, tasks), 1.0f);
	        float4 prev = vload4(pixIdx, pixels);
            color += prev;
            vstore4(color, pixIdx, pixels);
            //atomic_inc(&stats->samples);
        }

        // Put into raygen queue
        uint idx = atomic_inc(&queueLens->raygenQueue);
        raygenQueue[idx] = gid;

        WriteU32(seed, tasks, seed);
        return;
    }

    // Read hit material (to check if singular etc.)
    Material mat = materials[hit.matId];
    hit.N = tangentSpaceNormal(hit, tris, mat, textures, texData);
    bool backface = dot(hit.N, r.dir) > 0.0f;
    if (backface) hit.N *= -1.0f;
    float3 orig = hit.P - 1e-3f * r.dir;

    // Update updated hit struct
    writeHitSoA(hit, tasks, gid, numTasks);
    WriteU32(backfaceHit, tasks, backface);
    
    // Perform next event estimation: generate light sample + shadow ray
    if (params->sampleExpl && !BXDF_IS_SINGULAR(mat.type))
    {
        // Create probability distribution
        float envMapProb = (float)params->useEnvMap / max(1U, params->useEnvMap + params->useAreaLight); // 0.0, 0.5, or 1.0
        bool useEnvMap = rand(&seed) < envMapProb;
        bool useAreaLight = !useEnvMap && params->useAreaLight;

        // Importance sample env map (using alias method)
        if (useEnvMap)
        {
            float lightPickProb = envMapProb;

            float3 L;
            float directPdfW = 0.0f;
            int2 envMapDims = get_image_dim(envMap);
            const int width = envMapDims.x, height = envMapDims.y;
            EnvMapContext ctx = { width, height, pdfTable, probTable, aliasTable };
            sampleEnvMapAlias(rand(&seed), &L, &directPdfW, ctx);

            // Shadow ray
            float lenL = 2.0f * params->worldRadius;
            L = normalize(L);

            float cosTh = max(0.0f, dot(L, hit.N));
            float3 envMapLi = evalEnvMapDir(envMap, L) * params->envMapStrength;
            
            // Update path state
            WriteFloat3(shadowOrig, tasks, orig); // TODO: duplicate
            WriteFloat3(shadowDir, tasks, L);
            WriteF32(shadowRayLen, tasks, lenL);
            WriteF32(lastPdfDirect, tasks, directPdfW);
            WriteF32(lastCosTh, tasks, cosTh); // TODO: move to bsdf eval kernel?
            WriteF32(lastLightPickProb, tasks, lightPickProb);
            WriteFloat3(lastEmission, tasks, envMapLi);

            // Add to shadow queue
            uint idx = atomic_inc(&queueLens->shadowQueue);
            shadowQueue[idx] = gid;
        }

        // Sample area light source
        if (useAreaLight)
        {
            float lightPickProb = 1.0f - envMapProb;

            float directPdfA;
            float3 posL;
            AreaLight areaLight = params->areaLight;
            sampleAreaLight(areaLight, &directPdfA, &posL, &seed);

            // Shadow ray
            float3 L = posL - orig;
            float lenL = length(L) * 0.995f; // don't intersect with emitter itself
            L = normalize(L);

            float cosLight = max(dot(params->areaLight.N, -L), 0.0f);
            float directPdfW = pdfAtoW(directPdfA, lenL, cosLight);
            float cosTh = max(0.0f, dot(L, hit.N));
            float3 emission = params->areaLight.E;
            
            // Update path state
            WriteFloat3(shadowOrig, tasks, orig); // TODO: duplicate
            WriteFloat3(shadowDir, tasks, L);
            WriteF32(shadowRayLen, tasks, lenL);
            WriteF32(lastPdfDirect, tasks, directPdfW);
            WriteF32(lastCosTh, tasks, cosTh); // TODO: move to bsdf eval kernel?
            WriteF32(lastLightPickProb, tasks, lightPickProb);
            WriteFloat3(lastEmission, tasks, emission);

            // Only use samples that hit emissive side
            if (cosLight > 0.0f)
            {
                uint idx = atomic_inc(&queueLens->shadowQueue);
                shadowQueue[idx] = gid;
            }
            else // backface hit, don't even bother
            {
                WriteU32(shadowRayBlocked, tasks, 1);
            }
        }
    }

    // Place rays in proper material queue
    global uint *queue;
    global uint *queueLen;
    switch(mat.type)
    {
        case BXDF_DIFFUSE:
			queue = diffuseQueue;
            queueLen = &queueLens->diffuseQueue;
            break;
		case BXDF_GLOSSY:
			queue = glossyQueue;
            queueLen = &queueLens->glossyQueue;
            break;
		case BXDF_GGX_ROUGH_REFLECTION:
            queue = ggxReflQueue;
            queueLen = &queueLens->ggxReflQueue;
            break;
		case BXDF_GGX_ROUGH_DIELECTRIC:
			queue = ggxRefrQueue;
            queueLen = &queueLens->ggxRefrQueue;
            break;
        case BXDF_IDEAL_REFLECTION:		
		case BXDF_IDEAL_DIELECTRIC:
			queue = deltaQueue;
            queueLen = &queueLens->deltaQueue;
            break;
        default:
            printf("WF_LOGIC: INCORRECT MATERIAL TYPE!\n");
            return;
    }
    
    uint idx = atomic_inc(queueLen);
    queue[idx] = gid;

    WriteU32(seed, tasks, seed);
}