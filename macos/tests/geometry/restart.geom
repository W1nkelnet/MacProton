#version 450
layout(points) in;
layout(triangle_strip, max_vertices = 8) out;
layout(location=0) in vec4 vColor[];
layout(location=0) out vec4 gColor;
void main() {
  // Two separate triangles, left and right of the point
  for (int t = 0; t < 2; t++) {
    vec4 c = gl_in[0].gl_Position + vec4(t == 0 ? -0.2 : 0.2, 0, 0, 0);
    gColor = vColor[0];
    gl_Position = c + vec4(-0.08, -0.08, 0, 0); EmitVertex();
    gl_Position = c + vec4(0.08, -0.08, 0, 0); EmitVertex();
    gl_Position = c + vec4(0, 0.08, 0, 0); EmitVertex();
    EndPrimitive();
  }
}
