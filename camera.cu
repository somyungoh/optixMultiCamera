//
// Copyright (c) 2019, NVIDIA CORPORATION. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
//  * Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
//  * Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//  * Neither the name of NVIDIA CORPORATION nor the names of its
//    contributors may be used to endorse or promote products derived
//    from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

#include <vector_types.h>
#include <optix_device.h>
#include "optixMultiCamera.h"
#include "random.h"
#include "helpers.h"
#include <stdio.h>

extern "C" {
__constant__ Params params;
}

extern "C" __global__ void __raygen__pinhole_camera()
{
    const uint3 idx = optixGetLaunchIndex();
    const uint3 dim = optixGetLaunchDimensions();

    const CameraData* camera = (CameraData*) optixGetSbtDataPointer();

    const uint32_t image_index  = params.width*idx.y+idx.x;
    unsigned int seed           = tea<16>(image_index, params.subframe_index);

    // Subpixel jitter: send the ray through a different position inside the pixel each time,
    // to provide antialiasing.__raygen__pinhole_camera
    float2 subpixel_jitter = params.subframe_index == 0 ?
        make_float2(0.0f, 0.0f) : make_float2(rnd( seed ) - 0.5f, rnd( seed ) - 0.5f);

    float2 d = (make_float2(idx.x, idx.y) + subpixel_jitter) / make_float2(params.width, params.height) * 2.f - 1.f;
    float3 ray_origin = camera->eye;
    float3 ray_direction = normalize(d.x*camera->U + d.y*camera->V + camera->W);

    // :::::::::::::::  Multi-Camera :::::::::::::::: //

    // load texture data from the sampler
    // NOTE: It's supposed to be a list of textures but here I only have 1 texture loaded (index = 0)
    const DemandTextureSampler& sampler = params.demandTextures[0];
    float4 texColor = tex2D<float4>( 
        sampler.texture, 
        4.f * idx.x / params.width, 
        4.f * idx.y / params.height );

    // printf("u,v: %d,%d \ttexu,v: %.3f,%.3f\n", idx.x, idx.y, texColor.x, texColor.y);
    
    /*
    float2 d = make_float2(idx.x, idx.y) /
		make_float2(params.width, params.height) *
		make_float2(2.0f * M_PIf , M_PIf) +
		make_float2(M_PIf, 0);

    float3 angle = make_float3( cos(d.x) * sin(d.y),
				-cos(d.y),
				sin(d.x) * sin(d.y));
    */

    //float3 ray_direction = normalize(angle.x*camera->U + angle.y*camera->V + angle.z*camera->W);

    // ::::::::::::::::::::::::::::::::::::::::::::::: //

    RadiancePRD prd;
    prd.importance = 1.f;
    prd.depth = 0;

    optixTrace(
        params.handle,
        ray_origin,
        ray_direction,
        params.scene_epsilon,
        1e16f,
        0.0f,
        OptixVisibilityMask( 1 ),
        OPTIX_RAY_FLAG_NONE,
        RAY_TYPE_RADIANCE,
        RAY_TYPE_COUNT,
        RAY_TYPE_RADIANCE,
        float3_as_args(prd.result),
        reinterpret_cast<uint32_t&>(prd.importance),
        reinterpret_cast<uint32_t&>(prd.depth) );

    float4 acc_val = params.accum_buffer[image_index];
    if( params.subframe_index > 0 )
    {
        acc_val = lerp( acc_val, make_float4( prd.result, 0.f), 1.0f / static_cast<float>( params.subframe_index+1 ) );
    }
    else
    {
        acc_val = make_float4(prd.result, 0.f);
    }
    params.frame_buffer[image_index] = make_color( acc_val );
    params.accum_buffer[image_index] = acc_val;
}
