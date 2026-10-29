# Geometry Shader auf Metal

Metal hat keine Geometry-Shader-Stufe, MoltenVK übergab sie früher einfach nicht an Metal. Was ein Geometry Shader ausgibt, fehlte dann: Partikel, die aus Punkten zu Quads werden, Dreiecke, die er aussortiert, verdoppelt oder in andere Layer lenkt. MoltenVK-Patch 0007 bildet die Stufe mit Compute-Kernels nach, nach dem Vorbild der Tessellation.

## Ablauf eines Draws

1. **Vertex-Stufe als Compute-Kernel.** Der Vertex-Shader läuft wie bei der Tessellation als Kernel mit Stage-in. Er schreibt alle Ausgaben, die der Geometry Shader liest, gepackt in ein Array aus `uint4`, einen Datensatz pro Vertex und Instanz (bei indizierten Draws pro Index).
2. **Geometry-Stufe als Compute-Kernel.** Ein Thread pro Eingabe-Primitiv, Instanz und Invocation. Er liest die Vertices seines Primitivs aus dem Puffer: Punkte, Linien und Dreiecke, als Liste oder Strip, mit Adjacency. `OpEmitVertex` schreibt die aktuellen Ausgaben gepackt in einen festen Bereich von `OutputVertices` Plätzen dieses Threads und dazu einen Index. `OpEndPrimitive` schreibt einen Restart-Index (`0xFFFFFFFF`), ungenutzte Plätze werden ebenfalls Restarts. So braucht es keine Atomics, und die Reihenfolge der Primitive bleibt wie in D3D.
3. **Rasterisierung.** Ein indizierter Draw zeichnet Triangle- oder Line-Strips beziehungsweise Punkte aus diesem Index-Buffer. Sein Vertex-Shader spielt die ausgegebenen Vertices mit den Ausgaben des Geometry Shaders wieder ab, dahinter der unveränderte Fragment-Shader. Punktlisten kennen in Metal keinen Restart; der Shader schiebt solche Vertices aus dem Bild.

Alle drei Shader sind SPIR-V-Module, die `MVKGeometryShaderEmulation.h` aus Vertex- und Geometry-Shader ableitet. SPIRV-Cross übersetzt sie wie jeden anderen Shader. Die Schnittstelle zwischen den Stufen sind Location und Component der Ein- und Ausgaben. Built-ins wie Position, PointSize, Layer, ViewportIndex und ClipDistance belegen eigene Plätze, CullDistance kennt Metal nicht. Ausgaben, die der Geometry Shader nie schreibt, etwa ungenutzte Member von `gl_PerVertex`, bleiben weg, sonst würden zufällige Clip-Distanzen Dreiecke abschneiden.

Die Geometry-Stufe läuft an der Stelle der Tessellation Control und nutzt deren Ressourcen. Deskriptoren mit `VK_SHADER_STAGE_GEOMETRY_BIT` werden deshalb auch dieser Stufe zugeordnet. `PrimitiveIdIn` ist der Primitiv-Index innerhalb der Instanz, `InvocationId` die Invocation.

Indirekte Draws (`vkCmdDrawIndirect`, `vkCmdDrawIndexedIndirect`, auch mehrere auf einmal) rechnet ein kleiner Kernel auf der GPU in die Argumente der drei Stufen um: Stage-in-Region, Threadgroups beider Kernels, Parameter der Geometry-Stufe und den indizierten Draw. Weil die Anzahl erst auf der GPU feststeht, haben die Puffer eine feste Größe von 128 Ki Vertices und höchstens 128 MiB Ausgabe; größere Draws werden gekürzt.

Leitet ein Geometry Shader Dreiecke nur durch und wählt den Layer aus einer Eingabe, wie Unreal für Volumentexturen, schreibt weiterhin der Vertex-Shader den Layer (Patch 0006). Das spart die Compute-Stufen.

## Grenzen

- Geometry Shader zusammen mit Tessellation, Triangle Strips mit Adjacency, mehrere Streams und Transform Feedback werden nicht nachgebildet. Dann bleibt der Geometry Shader wie früher weg.
- Kann eine nachgebildete Pipeline nicht kompiliert werden, bleibt der Geometry Shader ebenfalls weg, statt dass die Pipeline scheitert. MoltenVK warnt dann.
- Jeder Draw mit Geometry Shader unterbricht den Render-Pass zweimal für die Compute-Stufen, wie bei der Tessellation.
- `MVK_CONFIG_EMULATE_GEOMETRY_SHADERS=0` schaltet die Nachbildung zum Vergleich ab.

## Test

`macos/tests/geometry/run.sh` zeichnet mit MoltenVK ohne Fenster und prüft Pixel: Punkte zu Quads (direkt, indiziert, instanziert, indirekt, mehrere indirekte Draws, indiziert indirekt), Dreiecke mit zwei Invocations und `PrimitiveIdIn`, Strip-Neustarts mitten im Shader und Punkt-Ausgabe mit ungenutzten Plätzen. Mit `MVK_CONFIG_EMULATE_GEOMETRY_SHADERS=0` scheitern diese Tests, wie es sein muss.
