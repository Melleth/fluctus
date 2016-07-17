#include "geom.h"

#define printVec3(title, v) printf("%s: { %.4f, %.4f, %.4f }\n", title, (v).x, (v).y, (v).z)
#define printVec4(title, v) printf("%s: { %.4f, %.4f, %.4f, %.4f }\n", title, (v).x, (v).y, (v).z, (v).w)
#define dbg(expr) if(get_global_id(0) == 0 && get_global_id(1) == 0) { expr; }
//#define dbg(expr) if(false) { expr; }

inline void swap(float *a, float *b)
{
  float tmp = *b;
  *b = *a;
  *a = tmp;
}

inline bool sphereIntersect(Ray *r, global Sphere *s, float *t)
{
    float t0, t1;
    float radius2 = s->R * s->R;

    // Geometric solution
    float3 L = s->P - r->orig;
    float tca = dot(L, r->dir);
    float d2 = dot(L, L) - tca * tca;
    if (d2 > radius2) return false;
    float thc = sqrt(radius2 - d2);
    t0 = tca - thc;
    t1 = tca + thc;

    if (t0 > t1)
    {
        float tmp = t0;
        t0 = t1;
        t1 = tmp;
    }

    if (t0 < 0)
    {
        t0 = t1;
        if (t0 < 0) return false;
    }

    *t = t0;

    return true;
}

#define NORMAL_X ((float3)(-1, 0, 0))
#define NORMAL_Y ((float3)(0, -1, 0))
#define NORMAL_Z ((float3)(0, 0, -1))

// Assign normal according to face hit
inline bool intersectSlab(Ray *r, AABB *box, float *tminRet, float *tMaxRet, float3 *N)
{
	float3 n;
	float3 dinv = 1.0f / r->dir;

    // X-axis
	n = NORMAL_X;
	float dinvx = dinv.x;
	float tmin = (box->min.x - r->orig.x) * dinvx;
	float tmax = (box->max.x - r->orig.x) * dinvx;

	if (dinvx < 0)
	{
		swap(&tmin, &tmax);
		n *= -1.0f;
	}

	if (tmax < 0)
	{
		return false;
	}

	*N = n;

    // Y-axis
	n = NORMAL_Y;
	float dinvy = dinv.y;
	float tminy = (box->min.y - r->orig.y) * dinvy;
	float tmaxy = (box->max.y - r->orig.y) * dinvy;

	if (dinvy < 0)
	{
		swap(&tminy, &tmaxy);
		n *= -1.0f;
	}

	if (tmin > tmaxy || tmax < tminy)
	{
		return false;
	}

	if (tminy > tmin)
	{
		tmin = tminy;
		*N = n;
	}

	if (tmaxy < tmax)
	{
		tmax = tmaxy;
	}

	if (tmax < 0)
	{
		return false;
	}

    // Z-axis
	n = NORMAL_Z;
	float dinvz = dinv.z;
	float tminz = (box->min.z - r->orig.z) * dinvz;
	float tmaxz = (box->max.z - r->orig.z) * dinvz;

	if (dinvz < 0)
	{
		swap(&tminz, &tmaxz);
		n *= -1.0f;
	}

	if (tmin > tmaxz || tmax < tminz)
	{
		return false;
	}

	if (tminz > tmin)
	{
		tmin = tminz;
		*N = n;
	}

	if (tmaxz < tmax)
	{
		tmax = tmaxz;
	}

	if (tmax < 0)
	{
		return false;
	}

	// Assign output variables
	*tminRet = tmin;
	*tMaxRet = tmax;
	
	return true;
}

inline bool box_intersect(Ray *r, AABB *box, float *tcurr, float *tminRet)
{
    float3 tmin = (box->min - r->orig) / r->dir;
    float3 tmax = (box->max - r->orig) / r->dir;

    float3 t1 = min(tmin, tmax);
    float3 t2 = max(tmin, tmax);

    float ts = max(t1.x, max(t1.y, t1.z));
    float te = min(t2.x, min(t2.y, t2.z));

    if (te < 0.0f || ts > *tcurr || ts > te) return false;
    *tminRet = max(0.0f, ts);

    return true;
}

// Möller-Trumbore
inline bool intersectTriangle(Ray *r, global Triangle *tri, float *tret, float *uret, float *vret)
{
	float3 s1 = tri->v1.p - tri->v0.p;;
	float3 s2 = tri->v2.p - tri->v0.p;
	float3 pvec = cross(r->dir, s2); // order matters!
	float det = dot(s1, pvec);

	// miss if det close to 0
	if (fabs(det) < FLT_EPSILON) return false;
	float iDet = 1.0f / det;

	float3 tvec = r->orig - tri->v0.p;
	float u = dot(tvec, pvec) * iDet;
	if (u < 0.0f || u > 1.0f) return false;

	float3 qvec = cross(tvec, s1); // order matters!
	float v = dot(r->dir, qvec) * iDet;
	if (v < 0.0f || u + v > 1.0f) return false;

	//float t = s2.dot(qvec) * iDet;
	float t = dot(s2, qvec) * iDet;

	if(t < 0.0f) return false;

	*tret = t;
	*uret = u;
	*vret = v;

	return true;
}

// BVH traversal using bitstacks
inline bool bvh_intersect(Ray *r, Hit *hit, global Triangle *tris, global GPUNode *nodes, global uint *indices)
{
    bool found = false;

    int top = 0;
    int lstack = 0;
    int rstack = 0;

    while(top != -1)
    {
    	GPUNode node = nodes[top];
    	bool trackback = false;

    	if (node.nPrims != 0) // leaf node
    	{
    		for (int i = node.iStart; i < node.iStart + node.nPrims; i++)
    		{
    			const uint k = indices[i];
    			global Triangle *triangle = &(tris[k]);

                float t, u, v;
    			if (intersectTriangle(r, triangle, &t, &u, &v) && t < hit->t) // add t checking into intersection routine?
    			{
                    hit->t = t;
                    hit->i = 0; // FOR TESTING!
                    hit->P = r->orig + hit->t * r->dir;
                    hit->N = tris[i].v0.n; // interpolate!
                    found = true;
    			}
    		}
    		trackback = true;
    	}

    	else // internal node
    	{
    		GPUNode lNode = nodes[top + 1]; // left child is right after current
    		GPUNode rNode = nodes[node.rightChild];

    		float t1, t2;
    		bool r1 = box_intersect(r, &(lNode.box), &(hit->t), &t1);
    		bool r2 = box_intersect(r, &(rNode.box), &(hit->t), &t2);

    		if (r1 && r2)
    		{
    			if (t1 <= t2)
    			{
    				// first left
    				top = top + 1;
    				lstack = (lstack|1)<<1;
    				rstack <<= 1;
    			}
    			else
    			{
    				// first right
    				top = node.rightChild;
    				rstack = (rstack|1)<<1;
    				lstack <<= 1;
    			}
    		}
    		else if(r1)
    		{
    			top = top + 1;
    			lstack <<= 1;
    			rstack <<= 1;
    		}
    		else if(r2)
    		{
    			top = node.rightChild;
    			lstack <<= 1;
    			rstack <<= 1;
    		}
    		else
    		{
    			trackback = true;
    		}

    	}

    	if (trackback)
    	{
    		bool f = false;

    		while(lstack != 0 || rstack != 0)
    		{
    			node = nodes[top];
    			if ((lstack & 1) != 0)
    			{
    				// visit right node
    				top = top +1;
    				lstack &= ~1;
    				lstack <<= 1;
    				rstack <<= 1;
    				f = true;
    				break;
    			}
    			else if((rstack & 1) != 0)
    			{
    				// visit left node
    				top = node.rightChild;
    				rstack &= ~1;
    				lstack <<= 1;
    				rstack <<= 1;
    				f = true;
    				break;
    			}

    			top = node.parent; // go to parent
    			lstack >>= 1;
    			rstack >>= 1;
    		}

    		if (!f) break;

    	}

    }

    return found;
}

inline Ray getCameraRay(const uint x, const uint y, global RenderParams *params)
{
    // Camera plane is 1 unit away, by convention
    // Camera points in the negative z-direction

    // NDC-space, [0,1]x[0,1]
    float NDCx = (x + 0.5f) / params->width;
    float NDCy = (y + 0.5f) / params->height;

    // Screen space, [-1,1]x[-1,1]
    float SCRx = 2.0f * NDCx - 1.0f;
    float SCRy = 2.0f * NDCy - 1.0f;

    // Aspect ratio fix applied horizontally
    SCRx *= (float)params->width / params->height;

    // Screen space coordinates scaled based on fov
    float scale = tan(toRad(0.5f * params->camera.fov)); // half of width
    SCRx *= scale;
    SCRy *= scale;

    // World space coorinates of pixel
    float3 rayTarget = params->camera.pos + params->camera.right * SCRx + params->camera.up * SCRy + params->camera.dir;
    float3 rayDirection = normalize(rayTarget - params->camera.pos);

    // Construct camera ray
    Ray r = { params->camera.pos, rayDirection };
    return r;
}

inline void calcNormalSphere(global Sphere *scene, Hit *hit)
{
    hit->N = normalize(hit->P - (scene +hit->i)->P);
}

// Will be replaced with a BVH in the future...
// The ray length encodes the maximum intersection distance!
inline Hit raycast(Ray *r, float tMax, global Sphere *scene, global Triangle *tris, global GPUNode *nodes, global uint *indices, global RenderParams *params)
{
    Hit hit = { (float3)(0.0f), (float3)(0.0f), tMax, -1 };

    // Spheres
    for(uint i = 0; i < params->n_objects; i++)
    {
        float t;
        bool found = sphereIntersect(r, &(scene[i]), &t);
        if(found && t < hit.t)
        {
            hit.t = t;
            hit.i = i;
            hit.P = r->orig + hit.t * r->dir;
            calcNormalSphere(scene, &hit);
        }
    }

    // AABBs
    AABB boxes[] = { {(float3)(-3, 1, -3), (float3)(-2, 2, -2)} };
    const uint n_boxes = 1;
    for(uint i = 0; i < n_boxes; i++)
    {
      float tmin, tmax;
      float3 N;
      bool found = intersectSlab(r, &(boxes[i]), &tmin, &tmax, &N); // fills in normal
      if(found && tmin < hit.t)
      {
          hit.t = tmin;
          hit.i = 2; // FOR TESTING ONLY!
          hit.P = r->orig + hit.t * r->dir;
          hit.N = N;
      }
    }

    // Triangles
    bvh_intersect(r, &hit, tris, nodes, indices);

    /*
    for(uint i = 0; i < params->n_tris; i++)
    {
      float t, u, v;
      bool found = intersectTriangle(r, &(tris[i]), &t, &u, &v);
      if(found && t < hit.t)
      {
          hit.t = t;
          hit.i = 4; // FOR TESTING!
          hit.P = r->orig + hit.t * r->dir;
          hit.N = tris[i].v0.n; // interpolate!
      }
    }
    */

    return hit;
}

inline float3 whittedShading(Hit *hit, global Sphere *scene, global Triangle *tris, global GPUNode *nodes, global uint *indices, global Light *lights, global RenderParams *params)
{
    float3 res = (float3)(0.0f);
    float3 lifted = hit->P + 1e-3f * hit->N;
    float3 V = normalize(params->camera.pos - hit->P);

    // Point light assumed for now
    for(uint i = 0; i < params->n_lights; i++)
    {
        float3 L = lights[i].pos - hit->P;
        float dist = length(L);
        L = normalize(L);

        Ray shadowRay = { lifted, L };
        Hit shdw = raycast(&shadowRay, dist, scene, tris, nodes, indices, params);
        float visibility = (shdw.i == -1) ? 1.0f : 0.0f; // early exits useless on GPU

        // Blinn-Phong

        // Testing material:
        float3 Ks = (float3)(1.0f);
        float glossiness = 0.025f; // probably not the right name...

        float3 H = normalize(L + V);
        float3 diffuse = scene[hit->i].Kd * max(0.0f, dot(L, hit->N));
        float3 specular = Ks * pow(max(0.0f, dot(hit->N, H)), 1.0f / glossiness);

        if(dot(hit->N, L) < 0) specular = (float3)(0.0f);

        float falloff = 1.0f / (dist * dist + 1e-5f);
        res += visibility * lights[i].intensity * falloff * (diffuse + specular);
    }

    return res;
}

kernel void trace(global float *out, global Sphere *scene, global Light *lights, global Triangle *tris, global GPUNode *nodes, global uint *indices, global RenderParams *params)
{
    const uint x = get_global_id(0); // left to right
    const uint y = get_global_id(1); // bottom to top

    if(x >= params->width || y >= params->height) return;

    //dbg(printf("nodes[1].parent = %d\n", nodes[2].parent));

    Ray r = getCameraRay(x, y, params);
    Hit hit = raycast(&r, FLT_MAX, scene, tris, nodes, indices, params);

    //float3 pixelColor = (hit.i == -1) ? (float3)(0.0f) : whittedShading(&hit, scene, tris, nodes, indices, lights, params);
    float3 pixelColor = (hit.i != -1) ? scene[hit.i].Kd : (float3)(0.0f);

    //float3 prev = vload4((y * width + x), out);
    //float3 newCol = 0.005f * pixelColor + prev;

    vstore4((float4)(pixelColor, 0.0f), (y * params->width + x), out); // (value, offset, ptr)
}
