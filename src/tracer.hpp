#pragma once

#include "clcontext.hpp"
#include <cmath>
#include "geom.h"
#include "window.hpp"
#include "math/float2.hpp"
#include "math/float3.hpp"
#include "math/matrix.hpp"

using namespace FireRays;

class Tracer
{
public:
    Tracer(int width, int height);
    ~Tracer();

    bool running();
    void update();
    void resizeBuffers();
    void handleKeypress(int key);
    void handleMouseButton(int key, int action);
    void handleCursorPos(double x, double y);

    void updateCamera();

private:
    PTWindow *window;
    CLContext *clctx;
    RenderParams params;    // copied into GPU memory
    float2 cameraRotation;  // not passed to GPU but needed for camera basis vectors
    float2 lastCursorPos;
    bool mouseButtonState[3] = { false, false, false };
    bool paramsUpdatePending = true; // force one param update
};
