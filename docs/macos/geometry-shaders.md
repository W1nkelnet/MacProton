# Geometry shaders on Metal

Metal has no geometry shader stage, and MoltenVK used to simply not pass it to Metal. Whatever a geometry shader emits was then missing: particles that grow from points into quads, triangles it discards, duplicates or routes into other layers. MoltenVK patch 0007 emulates the stage with compute kernels, modelled on tessellation.

## How a draw runs

1. **Vertex stage as a compute kernel.** As with tessellation, the vertex shader runs as a kernel with stage-in. It writes all outputs the geometry shader reads, packed into an array of `uint4`, one record per vertex and instance (per index for indexed draws).
2. **Geometry stage as a compute kernel.** One thread per input primitive, instance and invocation. It reads the vertices of its primitive from the buffer: points, lines and triangles, as lists or strips, with adjacency. `OpEmitVertex` writes the current outputs, packed, into a fixed range of `OutputVertices` slots of this thread, plus an index. `OpEndPrimitive` writes a restart index (`0xFFFFFFFF`), and unused slots become restarts too. This needs no atomics, and the order of the primitives stays as in D3D.
3. **Rasterization.** An indexed draw renders triangle or line strips, or points, from this index buffer. Its vertex shader replays the emitted vertices with the geometry shader's outputs, followed by the unchanged fragment shader. Point lists have no restart in Metal; the shader moves such vertices out of the picture.

All three shaders are SPIR-V modules that `MVKGeometryShaderEmulation.h` derives from the vertex and geometry shaders. SPIRV-Cross translates them like any other shader. The interface between the stages is the location and component of the inputs and outputs. Built-ins such as Position, PointSize, Layer, ViewportIndex and ClipDistance take slots of their own; Metal has no CullDistance. Outputs the geometry shader never writes, such as unused members of `gl_PerVertex`, are left out, or random clip distances would cut triangles.

The geometry stage runs in place of tessellation control and uses its resources. Descriptors with `VK_SHADER_STAGE_GEOMETRY_BIT` are therefore also assigned to that stage. `PrimitiveIdIn` is the primitive index within the instance, `InvocationId` the invocation.

For indirect draws (`vkCmdDrawIndirect`, `vkCmdDrawIndexedIndirect`, several at once too), a small kernel on the GPU converts the arguments for the three stages: stage-in region, threadgroups of both kernels, parameters of the geometry stage and the indexed draw. Because the count is known only on the GPU, the buffers have a fixed size of 128 Ki vertices and at most 128 MiB of output; larger draws are truncated.

If a geometry shader only passes triangles through and picks the layer from an input, as Unreal does for volume textures, the vertex shader keeps writing the layer (patch 0006). This saves the compute stages.

## Limits

- Geometry shaders together with tessellation, triangle strips with adjacency, multiple streams and transform feedback are not emulated. Then the geometry shader is left out as before.
- If an emulated pipeline cannot be compiled, the geometry shader is left out as well instead of the pipeline failing. MoltenVK warns then.
- Every draw with a geometry shader interrupts the render pass twice for the compute stages, as with tessellation.
- `MVK_CONFIG_EMULATE_GEOMETRY_SHADERS=0` turns the emulation off for comparison.

## Test

`macos/tests/geometry/run.sh` renders with MoltenVK without a window and checks pixels: points to quads (direct, indexed, instanced, indirect, several indirect draws, indexed indirect), triangles with two invocations and `PrimitiveIdIn`, strip restarts in the middle of the shader, and point output with unused slots. With `MVK_CONFIG_EMULATE_GEOMETRY_SHADERS=0` these tests fail, as they should.
