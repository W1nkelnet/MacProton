#version 450
layout(points) in;
layout(points, max_vertices = 4) out;
layout(stream = 0, xfb_buffer = 0, xfb_offset = 0, xfb_stride = 16, location = 0) out vec4 v;
layout(stream = 1, xfb_buffer = 1, xfb_offset = 0, xfb_stride = 16, location = 1) out vec4 w;
void main() {
  float x = gl_in[0].gl_Position.x;
  v = vec4(x, 0.0, float(gl_InvocationID), 3.0); gl_Position = vec4(0.0); EmitStreamVertex(0);
  if (int(x) % 2 == 1) {
    w = vec4(x, 1.0, 0.0, 4.0); EmitStreamVertex(1);
    w = vec4(x, 2.0, 0.0, 4.0); EmitStreamVertex(1);
  }
}
