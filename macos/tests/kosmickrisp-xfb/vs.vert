#version 450
void main() { gl_Position = vec4(float(gl_VertexIndex), 0.0, 0.0, 1.0); gl_PointSize = 1.0; }
