# Geometry Shader auf Metal – Entwurf

Metal hat keine Geometry-Shader-Stufe, MoltenVK meldet `geometryShader` nicht und übergeht die Stufe beim Anlegen einer Pipeline. Metal lehnt die Pipeline dann ab, weil der Fragment-Shader Eingaben erwartet, die der Vertex-Shader nicht schreibt. D3D11 und D3D12 setzen Geometry Shader aber voraus, und Spiele nutzen sie vor allem für Partikel: Aus jedem Punkt wird ein Quad. Horizon Zero Dawn legt so neun Pipelines an, deren Partikel heute fehlen.

## Ansatz: Compute wie bei der Tessellation

MoltenVK emuliert Tessellation bereits mit Compute-Stufen mitten im Render-Pass (`MVKCmdDraw`, `kMVKGraphicsStageVertex` und `kMVKGraphicsStageTessControl`). Ein Geometry Shader passt in dasselbe Schema:

1. **Vertex-Stufe als Compute-Kernel.** SPIRV-Cross übersetzt den Vertex-Shader mit `capture_output_to_buffer` wie für die Tessellation, die Ausgaben landen in einem Buffer, ein Eintrag pro Vertex (bei indizierten Draws pro Index).
2. **Geometry-Stufe als Compute-Kernel.** Neuer Modus in SPIRV-Cross für `ExecutionModelGeometry`: ein Thread pro Eingabe-Primitiv und Invocation. Die Eingabe-Arrays lesen aus dem Vertex-Buffer an den Indizes des Primitivs (Punkte, Linien, Dreiecke, mit Adjacency). `OpEmitVertex` schreibt die aktuellen Ausgaben in einen festen Bereich von `OutputVertices` Plätzen pro Primitiv, `OpEndPrimitive` beginnt einen neuen Strip. Aus den Strips entstehen Dreiecke (oder Linien und Punkte) in einem Index-Buffer, ungenutzte Plätze werden degenerierte Primitive. So braucht es keine Atomics, und die Reihenfolge bleibt wie in D3D.
3. **Rasterisierung.** Ein durchreichender Vertex-Shader, den SPIRV-Cross aus der Ausgabe-Schnittstelle des Geometry Shaders erzeugt, liest den Ausgabe-Buffer an `[[vertex_id]]`. Dazu kommt der unveränderte Fragment-Shader und ein indizierter Draw über den erzeugten Index-Buffer.

Built-ins: `PrimitiveIdIn` ist der Primitiv-Index, `InvocationId` die Invocation. `Layer` und `ViewportIndex` als Ausgaben gibt der durchreichende Vertex-Shader als `[[render_target_array_index]]` und `[[viewport_array_index]]` aus. Mehrere Streams und Transform Feedback bleiben außen vor.

## Aufwand

- SPIRV-Cross: Geometry-Modus für MSL (Eingaben, Emit/EndPrimitive, Strip-Zerlegung, durchreichender Vertex-Shader).
- MoltenVK: Pipeline mit drei Stufen, Buffer-Größen aus `OutputVertices`, alle Draw-Varianten (direkt, indiziert, indirekt) und Multiview.
- Test: kleines D3D12-Programm in `docs/macos/` mit Punkt-zu-Quad-Shader, danach Horizon Zero Dawn.

Ein Weg über Metal-Mesh-Shader wäre schneller zur Laufzeit, braucht aber Mesh-Pipelines in MoltenVK und ein Zusammenführen von Vertex- und Geometry-Shader auf SPIR-V-Ebene.
