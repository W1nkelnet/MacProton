#version 450
layout(location=0) in vec2 inPos;
layout(location=1) in vec4 inColor;
layout(location=0) out vec4 vColor;
layout(location=1) out float vSize;
layout(push_constant) uniform PC { float instanceShift; } pc;
void main() {
  gl_Position = vec4(inPos + vec2(gl_InstanceIndex * pc.instanceShift, 0), 0, 1);
  vColor = inColor; vSize = 0.1;
}
