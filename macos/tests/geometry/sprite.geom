#version 450
layout(points) in;
layout(triangle_strip, max_vertices = 4) out;
layout(location=0) in vec4 vColor[];
layout(location=1) in float vSize[];
layout(location=0) out vec4 gColor;
void main() {
  for (int i = 0; i < 4; i++) {
    vec2 o = vec2(i & 1, i >> 1) * 2.0 - 1.0;
    gl_Position = gl_in[0].gl_Position + vec4(o * vSize[0], 0, 0);
    gColor = vColor[0];
    EmitVertex();
  }
  EndPrimitive();
}
