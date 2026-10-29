#version 450
layout(xfb_buffer = 0, xfb_offset = 0, xfb_stride = 32, location = 0) out vec4 v;
layout(xfb_buffer = 0, xfb_offset = 16, location = 1) out vec4 w;
void main() {
  v = vec4(float(gl_VertexIndex), 7.0, float(gl_InstanceIndex), 1.0);
  w = vec4(1.0, 2.0, 3.0, float(gl_VertexIndex));
  gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
}
