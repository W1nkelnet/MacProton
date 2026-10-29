#version 450
layout(points) in;
layout(points, max_vertices = 4) out;
layout(location=0) in vec4 vColor[];
layout(location=0) out vec4 gColor;
void main() {
  gColor = vColor[0];
  gl_PointSize = 9.0;
  gl_Position = gl_in[0].gl_Position + vec4(0, 0.2, 0, 0); EmitVertex();
  gl_Position = gl_in[0].gl_Position - vec4(0, 0.2, 0, 0); EmitVertex();
}
