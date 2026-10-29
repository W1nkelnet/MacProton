#version 450
layout(triangles, invocations = 2) in;
layout(triangle_strip, max_vertices = 3) out;
layout(location=0) in vec4 vColor[];
layout(location=0) out vec4 gColor;
void main() {
  for (int i = 0; i < 3; i++) {
    gl_Position = gl_in[i].gl_Position + vec4(gl_InvocationID * 1.0, 0, 0, 0);
    gColor = gl_InvocationID == 0 ? vColor[i] : vec4(0, 1, 1, 1) * float(gl_PrimitiveIDIn + 1) * 0.5;
    EmitVertex();
  }
}
