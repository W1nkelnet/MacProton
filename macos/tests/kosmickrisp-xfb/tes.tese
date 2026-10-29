#version 450
layout(triangles, equal_spacing, ccw) in;
layout(xfb_buffer = 0, xfb_offset = 0, xfb_stride = 16, location = 0) out vec4 v;
void main() {
  v = vec4(gl_TessCoord, float(gl_PrimitiveID) + 10.0);
  gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
}
