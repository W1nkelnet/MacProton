#version 450
layout(points) in;
layout(triangle_strip, max_vertices = 6) out;
layout(xfb_buffer = 0, xfb_offset = 0, xfb_stride = 16, location = 0) out vec4 v;
void main() {
  int n = int(gl_in[0].gl_Position.x) % 3;   /* 0, 1 or 2 triangles */
  for (int t = 0; t < n; t++) {
    for (int i = 0; i < 3; i++) {
      v = vec4(gl_in[0].gl_Position.x, float(i), float(t), 2.0);
      gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
      EmitVertex();
    }
    EndPrimitive();
  }
}
