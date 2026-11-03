# Proton on macOS – porting roadmap

Branch: `macos-port` (branched from `proton_11.0`, on Proton's `bleeding-edge` since late October 2026)

State of the components:

| Component | Version |
|---|---|
| Wine | 11.0, Proton `bleeding-edge` (674d3cdd) |
| DXVK | `master` (0cfe089, reports 3.1.1), dxbc-spirv 687a301 |
| vkd3d-proton | 3.1 (4522cc1) |
| MoltenVK | `main` after 1.4.2 (5189f8de), SPIRV-Cross aa217aeb |

Khronos deprecated MoltenVK in October 2026 and recommends KosmicKrisp on
Apple silicon, a Vulkan driver from Mesa on Metal 4 (macOS 26+). MacProton
builds both (`build.sh` step `kosmickrisp`, Mesa daa925c3 with
`macos/patches/mesa`) and uses KosmicKrisp as the default from macOS 26 on;
MoltenVK stays selectable in Settings and per game in its launch options
(`MACPROTON_VULKAN_DRIVER` in `run.sh`).

KosmicKrisp for MacProton:
- The tools `mesa_clc` and `kk_clc` are built natively (Homebrew LLVM, libclc, SPIRV-LLVM-Translator), the driver then for x86_64 without LLVM, because Wine runs under Rosetta
- Wine loads `libMoltenVK.dylib` directly and calls `vkGetInstanceProcAddr`; KosmicKrisp is a loader ICD. `macos/kosmickrisp/shim.c` is therefore called `libMoltenVK.dylib`, negotiates the ICD interface and passes calls on, plus `vkGetDeviceProcAddr` and `vkCreateMetalSurfaceEXT`, by which Wine recognizes `VK_EXT_metal_surface`
- Mesa patch 0001: `fillModeNonSolid` (Metal draws triangle edges as lines, points not); without it DXVK rejects the device. Timestamp pools over 4096 entries are spread over several Metal counter heaps (Unreal with D3D12 creates 8192, otherwise “Out of video memory”)
- vkd3d patch 0008: vkd3d treats KosmicKrisp like MoltenVK as a portability device and starts without the features both lack
- Mesa patches 0002 and 0003: transform feedback (`VK_EXT_transform_feedback`), that is stream output for D3D11 and D3D12 and the base for OpenGL through Zink. Mesa's `poly` library, with which KosmicKrisp emulates geometry shaders, already writes the vertices from the GS's raster shader; the driver now keeps its count and pre-GS programs, runs them before the GS while transform feedback is active, and has buffer bindings, counters and `vkCmdDrawIndirectByteCountEXT`. If the vertex or tessellation shader captures (vkd3d, Zink), the driver appends `poly`'s pass-through GS. Multiple streams and buffers work, as do transform feedback queries (Mesa patch 0004, plus pipeline statistics pools, which DXVK creates unchecked; they report zeros). Fixed in `poly`: a GS invocation without output creates a stand-in primitive on side effects, whose vertices otherwise overwrote those of the next invocation. Test: `macos/tests/kosmickrisp-xfb/run.sh` (static and dynamic vertex count, indirect, instances, two streams, overflow, resuming through the counter, VS and TES, pipeline cache)
- Mesa patch 0007: MetalFX upscaling on KosmicKrisp too. With `MESA_WSI_METAL_UPSCALING=metalfx` (run.sh sets it from `MVK_CONFIG_UPSCALING`) the drawables get the pixel size of the window on screen; on present, `MTL4FXSpatialScaler` scales into a private texture that is copied into the drawable, alpha set to 1. Patch 0006: `MESA_WSI_METAL_FILTER=nearest` for “Pixel-exact”. Test: `macos/tests/kosmickrisp-present/run.sh`; Forager 1280×720 → 2560×1440
- Mesa patch 0005: `MESA_KK_LIGHT_BARRIERS` (experiment, off): render encoders end without a barrier, the application's barriers wait at the next encoder. Superseded by patch 0037, see below
- Mesa patch 0008: `vkWaitForPresent` returns as soon as the image is in the drawable on the GPU, as with MoltenVK. Waiting for the `presentedHandler` cost a vsync: vkd3d limits its frame latency with present waits, and Medieval Dynasty ran at 30 instead of 60 fps with a half-idle GPU. `MESA_WSI_METAL_PRESENT_WAIT=displayed` restores the old behavior
- Mesa patch 0009 and `MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION=1` in run.sh: otherwise Metal compiles only a few shaders at once. Devolverland Expo hung on KosmicKrisp because `dxvk-cs` waited behind DXVK's background compiles while building pipelines until Unreal gave up after 120 s
- Tested: all ten games that run under MoltenVK also run on KosmicKrisp up to their menu (smoke tests `start-12`, `start-13`). GPU time in the main menu after 100 s, measured with `macos/gpu-trace.py`:

  | Game | MoltenVK | KosmicKrisp | with `MESA_KK_LIGHT_BARRIERS` |
  |---|---|---|---|
  | Medieval Dynasty (D3D12) | 13.0 ms/frame, 59 fps | 12.4 ms/frame, 59 fps (with patch 0008) | 17.3 ms/frame before patch 0008 instead of 21.1 |
  | Horizon Zero Dawn (D3D12) | 6.45 ms/frame | 6.83 ms/frame | 6.35 ms/frame |
  | Green Hell (D3D11) | 53 ms/frame, 18 fps | 9.4 ms/frame, 34 fps | 10.9 ms/frame |
  | Raft (D3D11), GPU load | 761 ms/s | 390 ms/s | – |
  | Kebab Chefs (D3D11), GPU load | 795 ms/s | 474 ms/s | 554 ms/s |

  For Raft and Kebab Chefs the trace lacks frame numbers under KosmicKrisp, so only the GPU load per second counts there
- Mesa patch 0010: presents go through a Metal queue of their own. Metal 4 queues wait on the GPU until the display releases a drawable; on the main queue this held up all work behind it, including the next frame, and the GPU sat half idle. `MESA_KK_PRESENT_QUEUE=0` restores the old behavior
- Mesa patch 0011: the swapchain counts as suboptimal only when the layer's size changes, as with MoltenVK. Before, every present returned `VK_SUBOPTIMAL_KHR` as soon as a game rendered smaller than its window, and vkd3d recreated the swapchain about 10,000 times in two minutes in Medieval Dynasty
- Mesa patch 0012: `MESA_WSI_METAL_FPS=1` writes the frames per second to stderr every second. The Metal HUD counts too, but costs time per encoder on the thread creating it, under KosmicKrisp that is DXVK's CS thread, and skews the comparison of the drivers (Kebab Chefs, menu: KosmicKrisp 20.4 and MoltenVK 33.1 fps with the HUD, 19.7 and 22.0 without)
- Mesa patches 0013 and 0016: KosmicKrisp creates Mesa's shader cache on disk, `run.sh` puts it in `~/Library/Caches/MacProton/mesa_shader_cache` with up to 4 GB. Without it every start compiled all shaders to MSL again, about 15 ms CPU per pipeline under Rosetta; Metal caches the libraries compiled from it itself. The device lacked a memory cache for this, and the cache's name read 16 bytes past the build ID, which differed from start to start. Horizon Zero Dawn precompiles about 23,000 pipelines in its main menu: on the first start KosmicKrisp manages about 200 per minute, on the second the known 5,800 come from the caches in under a minute
- Mesa patch 0014: `MESA_KK_COMPILE_STATS=1` writes every two seconds how many pipelines were compiled and how many came from the cache, and how long MSL generation, Metal libraries and Metal pipelines took, summed over all threads
- Mesa patch 0015: the MSL of finished pipelines stays compressed in memory with LZFSE (Apple's libcompression, 6.5 times smaller, 1 ms per 225 KB under Rosetta) and is decompressed only for serializing. Horizon Zero Dawn took about 18 GB with 23,000 pipelines and swapped on 16 GB; now it stays at 4.2 GB after 9,500 pipelines, about 32 instead of 420 KB per pipeline
- Mesa patch 0017 (replaced by 0020): `MESA_KK_NULL_IMAGE_SELECT=1` reads images and textures through empty descriptors too and then selects zero, instead of wrapping every access in a branch. Horizon Zero Dawn's largest compute shader (4,126 texture accesses) takes 8.6 instead of 14.4 s in Metal's front end; the M3 reads through an empty resource ID without faulting. Off, because the branch skips the accesses and vkd3d binds many empty descriptors: Medieval Dynasty ran at 15–20 instead of 22 fps
- Mesa patch 0018: the MSL declares its SSA values without zero initialization; each is written before it is read. The zeros made up a tenth of the text: Metal compiles 40 shaders from Horizon Zero Dawn 9 % faster, the largest in 17.2 instead of 24.9 s
- Mesa patch 0020: reads through empty descriptors read a zeroed 1×1 texture of the same type (per dimension for float, int and uint), whose resource IDs are in the root table, instead of branching on every access. Replaces 0017. Size queries, writes, atomics, depth comparisons, sparse and multisample still branch; unlike an empty descriptor, the texture returns something only where the sampler returns its border color. Rise of the Tomb Raider (DX12, High, 1710×1107, warm caches): 24.2 instead of 18.6 fps on average over the three benchmark scenes. `MESA_KK_NULL_TEXTURES=0` branches as before
- Mesa patches 0019 and 0021: texel buffers in the format R32G32B32, which D3D12 requires for typed buffer SRVs and Metal does not know, are R32 texel buffers of three times the width; their descriptor (now 16 bytes for texel buffers) marks them, and reads fetch the three components one by one. Before, Rise of the Tomb Raider's benchmark crashed in `vkCreateBufferView`, and on MoltenVK it still does; 0019 makes buffer views of unknown formats fail instead of crashing
- Mesa patch 0022: one disk cache for the whole process, living until its end. Rise of the Tomb Raider's launcher hung now and then in `vkDestroyInstance`, because tearing down the cache waited for its writer threads, which never woke up
- Mesa patches 0023 and 0025: `MESA_KK_COMPILE_STATS=1` names shaders whose lowering or compiling takes longer than a second, and the CPU time of MSL generation (through `thread_info`; `CLOCK_THREAD_CPUTIME_ID` reports almost nothing under Rosetta). Rise of the Tomb Raider's tessellation control shaders take 12 s each, mostly waiting while Metal's compiler processes occupy all cores; the CPU time of MSL generation is about 6 ms per pipeline
- Mesa patch 0024: MSL without `vsnprintf` for `%d`, `%i`, `%u`, `%s` and `%c`, which made up half of `nir_to_msl` under Rosetta. Up to the main menu of Rise of the Tomb Raider (2,007 pipelines) 12.3 instead of 13.6 s CPU, byte for byte the same MSL
- Mesa patch 0026: `MESA_KK_CACHE_BUILD_ID` names the shader caches for development, so that builds which do not change the shader compiler keep using the caches of an earlier one. Otherwise every build starts with empty caches, and Rise of the Tomb Raider needs ten minutes to warm up
- Mesa patch 0027: the tessellation emulation fills the SIMD groups. The tessellator ran with one patch per threadgroup, the TCS with one patch per threadgroup of its output vertices, that is with 1–4 of 32 lanes; now 64 patches per group in the tessellator and as many patches in the TCS as fit into 32 lanes. Indirect draws started VS and TCS with 64 or n times too many threads, and the TCS threads read and wrote past the patches. Mountain peak (tessellates the snow), warm caches, alternating with cool-down pauses: 30.6/30.8 instead of 29.2/28.9 fps; without the game's tessellation 38 fps
- Mesa patch 0028: the command pool keeps large command buffer allocations (over 128 KB, which tessellation and geometry shaders take on every draw) in power-of-two sizes up to 64 MB for reuse; before, each became a new Metal heap in the residency set, which cost a sixth of a render thread in the tessellated scenes. Also, the pool did not initialize its counter of free small buffers. Mountain peak: 32.3/32.1 instead of 31.0/30.7 fps
- First start of Horizon Zero Dawn with empty caches after patches 0018–0028: 8,288 instead of 5,159 pipelines in 25 minutes, Metal's compiler 0.9 instead of 1.3 s per pipeline, memory constant at 4.1 GB. The MSL has a median size of 65 instead of 81 KB, the largest shader 1.9 instead of 4.0 MB
- Mesa patch 0029: Metal builds the pipelines on a compile queue of the device with one thread per core. Before, `vkCreate*Pipelines` waited for Metal, so a game compiled at most as many pipelines at once as it has threads for it; Horizon Zero Dawn has six. The MSL is still generated on creation, libraries and pipeline states afterwards in the background. Binding a shader waits for it, or builds it itself if the queue has not started it yet; draws and dispatches with a pipeline Metal could not build are skipped. First start of Horizon Zero Dawn with empty caches, 15 minutes: Metal built 8,644 instead of 4,240 pipelines, its compiler occupied 6.4 instead of 3.3 cores, and memory rose to 5.3 GB with three times as many pipelines created. Rise of the Tomb Raider with warm caches unchanged at 27.1 fps
- Mesa patch 0031: destroying a shader no longer waits for its Metal build. Horizon Zero Dawn destroys pipelines while loading whose builds were queued behind thousands of others; its loading screen therefore ran at 0.1 fps. Now the build holds a reference, a build not started yet is abandoned and its MSL freed right away, and the last reference frees the shader. `util_queue_finish` cannot be used for this when destroying the device, because it expects every thread the queue may create at a barrier; the device counts its open builds itself. First start of Horizon: loading screen at about 50 instead of 0.1 fps, the game reaches its world and renders it correctly. Memory grows with the finished pipelines (about 0.55 MB per pipeline state, 9.2 GB at 15,800); while Metal works through the backlog, the game runs at about 10 fps
- Mesa patch 0032: SSA values are declared in the innermost loop that holds all their uses instead of at the top of the function. Otherwise Metal's compiler runs the breaking branch of a waterfall loop (`simd_broadcast_first`, then `if (v == first) { simd_sum; break; }`) with every thread of the SIMD group as soon as `first` is declared outside the loop. All 928 wave tests of vkd3d-proton pass; before, `test_shader_waveop_maximal_convergence` failed
- Mesa patch 0033: 2D and 2D array views also get a Metal view of the other type (the first layer for arrays), the descriptor carries both IDs (the array ID in former padding), and `texture2d_array` declarations load the array ID. D3D12 games bind array views to Texture2D and the other way round; other APIs then read the first layer, Metal reads garbage. Fixes Unreal Engine 5 with D3D12 (see below)
- In game, same save and view, M3 with 16 GB, window 1710×1107 points, without the Metal HUD. Frames per second over 30 s from `MESA_WSI_METAL_FPS=1` or `MVK_CONFIG_PERFORMANCE_TRACKING=1` (evaluated with `macos/fps.py`), GPU load from the Metal System Trace:

  | Game | MoltenVK | KosmicKrisp without patch 0010 | KosmicKrisp |
  |---|---|---|---|
  | Medieval Dynasty (D3D12), village | 22.7 fps, GPU 75 % | 14.5 fps, GPU 50 % | 22.1 fps, GPU 64 % |
  | Green Hell (D3D11), jungle | 16.5 fps, GPU 97 % | – | 23.1 fps, GPU 64 % |
  | Green Hell, main menu (with HUD) | 12 fps | 21 fps | 29 fps |
  | Kebab Chefs (D3D11), menu, present requests in the trace | 22.0 fps | – | 19.7 fps |

  Under KosmicKrisp a third of the GPU stays idle: KosmicKrisp translates commands to Metal already while recording, on DXVK's CS thread, MoltenVK only on submit, on the submit thread. In Kebab Chefs `dxvk-cs` is therefore almost 90 % busy. Raft switches between day and night and is no good for comparisons. Horizon Zero Dawn's benchmark loads on 16 GB with neither driver: the game creates about 23,000 pipelines while loading, KosmicKrisp holds about 9 GB of shader source for them in memory, and the Mac swaps
- DXVK patch 0005: mipmaps through DXVK's single-pass compute shader on KosmicKrisp. A third of `dxvk-cs`'s time in Kebab Chefs' menu went into `vkCmdBlitImage`: the game has DXVK generate about 110 mip levels per frame, and KosmicKrisp blits each through Mesa's meta code, with new texture views and a Metal render pass of its own. With one compute dispatch per chain the menu runs at 50 instead of 29 fps, and the GPU is 76 instead of 63 % busy; Green Hell, which hardly generates mipmaps, stays the same (28.4 and 28.7–31.4 fps). The shader samples levels that do not halve exactly at slightly different positions than a blit; test `docs/macos/d3d11-mipgen.c` (eight formats and sizes, multi-pass and arrays) checks each chain against both filters. Mesa patch 0034: meta views (blits, clears, copies) skip the extra view of the other type from patch 0033
- Mesa patch 0035: DXVK records every render pass into a secondary command buffer on tiling GPUs, so it can choose load and store ops late. KosmicKrisp replays secondaries from Mesa's command queue, but began a Metal command buffer with allocator for each, which stayed empty: a ninth of `dxvk-cs`'s time in Kebab Chefs. Turning DXVK's tiler mode off (`dxvk.tilerMode = False`) would save the replay, but costs far more GPU time: the menu then runs at 37 instead of 50 fps with the GPU 86 instead of 69 % busy. The menu is now CPU-bound in the game and in `dxvk-cs` alike (47 fps without VSync too); Green Hell is limited by its own main thread, which runs almost fully under Rosetta. Mesa patch 0036: beginning a render pass no longer resets all eight color attachments of the descriptor it has just created (about 40 Metal calls per render pass, 3 % of `dxvk-cs` in Kebab Chefs). Afterwards `dxvk-cs` waits 38 % of the time; of the rest, DXVK's own code is about 40 % and KosmicKrisp about 60 %, mostly replaying the draws and Metal creating render encoders. vkd3d-proton's suite (44 million checks) gives the same results as with the v0.1.0.14 driver; `test_placed_image_alignment`, which places 64 GB of render targets in one heap, fails now and then with both after the allocation stress tests
- Mesa patch 0037: every encoder ended with a barrier on all stages, and at the end of a render encoder Metal implements it with a compute pass of its own (`encodeSyncCompute…`), which cost the recording thread (4 % of `dxvk-cs` in Raft) and above all the GPU: Kebab Chefs' menu kept it busy 79 % of the time, without it 33 %. Now a render encoder ends without the barrier and the encoder after it, as well as the first of every command buffer, waits for all earlier work at its start; the order stays the same. Patch 0005's light barriers, which only waited for the application's barriers, broke 131 checks of Wine's D3D9 tests and vkd3d-proton's depth-stencil copies (races); the new mode passes both suites with the same results as before. `MESA_KK_LIGHT_BARRIERS=2` is the default, 1 the old experiment, 0 the barrier after every encoder. Measured alternately with 0:

  | Game | `MESA_KK_LIGHT_BARRIERS=0` | patch 0037 |
  |---|---|---|
  | Raft, main menu | 50.0 / 48.1 fps | 52.2 / 50.4 fps |
  | Green Hell, in game | 22.8 / 23.5 fps | 25.8 / 24.7 fps |
  | Medieval Dynasty (D3D12), in game | 16.3 fps | 17.4 fps |
  | Rise of the Tomb Raider, benchmark mean | 25.4 fps | 25.7 fps |
- Memory of Horizon Zero Dawn on KosmicKrisp (November 2026, warm Metal cache, savegame, 16 GB): about 9.7 GB after 10 minutes (loading screen and world), of which 4.3 GB are the game's Vulkan memory, 2.3 GB Windows-side allocations and about 1 GB malloc; MoltenVK reaches 12–13 GB, swaps and was still on the loading screen after 9 minutes. Each pipeline Metal has built costs about 0.15–0.5 MB, mostly outside the driver's own allocations. KosmicKrisp's `VK_EXT_memory_budget` reports only about a quarter of the free memory: Mesa's `os_get_available_system_memory` multiplies the page counts, which are in 16 KB kernel pages, by `PAGE_SIZE`, which is 4 KB under Rosetta. Correcting it (budget 7 instead of 1.7 GB) let Horizon fill 7.5 GB of Vulkan memory; the Mac then swapped and the game fell to 30 and later 4 fps. Kebab Chefs runs at 46 fps with either budget. The accidental quarter therefore stays; a budget for unified memory would have to leave room for the game's own CPU memory
- Horizon Zero Dawn in game on KosmicKrisp (Ultra preset, 1710×1107, savegame in Meridian at night): 8–11 fps, the GPU busy about 65 ms per frame, 80 % in steady state. A frame has about 250 render and 140 compute encoders; one fragment pass alone takes 14 ms, the others 1–3 ms. No thread of the game is saturated (the busiest at 43 %). Skipping the draws of one render pass type at a time (by attachment size and formats, with temporary instrumentation) named it: a full-resolution pass with a single RGBA16F color attachment and no depth that draws one full-screen triangle. Its fragment shader (about 13,700 lines of MSL) samples 101 textures from the descriptor heap, 186 samples per pixel with one sampler and one explicit LOD. Skipping it lowers the fragment time from 50 to 34 ms per frame. The cost was the driver's: compiled without robustness (test only) the pass takes about 2 ms. Its 400 robust constant reads each ended up in a branch of their own, which Metal keeps; Mesa patch 0038 removes the branches (see below). Leaving out the null descriptor handling for its samples, reading the constants as vectors, the `device` address space and leaving out the descriptor index clamps changed little or made it slower
- Mesa patch 0038: a robust uniform buffer read became `off < size ? *(base + off) : 0` in MSL, one branch per read, and Metal keeps them. Now every read loads unconditionally, from a zero buffer of the device when the offset is out of bounds, and the result is selected; null and unwritten descriptors read the zero buffer, not address 0. Horizon's lighting pass falls from 15–16 to 2–2.5 ms and the fragment work of a frame from 51 to 36.6 ms. The frame rate in that scene stays at about 10 fps: a frame takes about 120 ms, the GPU works about 58 ms of it, so something else limits it there. Rise of the Tomb Raider with warm caches is unchanged or slightly faster (mean 22.5 and 22.4 instead of 21.3 and 22.7 fps). Wine's D3D9 tests, vkd3d-proton's test suite and the D3D11 tests give the same results as before
- Mesa patch 0039: Metal keeps the pipelines it builds in a cache per app, for every game Wine's (`org.winehq.wine`), which stays at about 2.4 GB. Rise of the Tomb Raider creates all of its 13,659 pipelines at every start. After a run of another game or driver build, Metal built them all again, about 2,000 s on KosmicKrisp's compile threads and 500 s of CPU in Metal's compiler while the benchmark ran: Geothermal Valley at 13 instead of 18 fps, the benchmark 225 instead of 125 s. Comparing two driver builds alternately therefore measured mostly this; each build needs two runs in a row. With patch 0038 the game's pipelines no longer quite fit, and even back-to-back starts rebuilt some during Geothermal Valley, with frames of 150–600 ms. KosmicKrisp now keeps the pipelines Metal builds in Metal 4 archives of each game's own, in `kosmickrisp_pipelines/<exe>` next to Mesa's shader cache. A pipeline from an archive takes about 0.1 instead of 11–13 ms and leaves Metal's cache alone. The pipelines Metal builds are captured and written to a new archive every 1,024 pipelines, 5 s after the last one (at most every 30 s), and when the device goes; Proton ends games without destroying it. Writing must not overlap pipeline builds (Metal crashes; libraries are fine), so builds wait for it: 43 s in all on a first start of Rise of the Tomb Raider, at most 8 s at a time. Metal can't add to an archive: with more than 32 files, the next start captures every pipeline it creates into a new generation, and the start after that drops the older one. Rise of the Tomb Raider takes 557–636 MB in 15–17 files. After a run with another driver: pipelines 37 instead of 1,900 s, benchmark 125 instead of 227 s, mean 22.3 instead of 19.0 fps, Geothermal Valley's 1 % low 9.0 instead of 1.8 fps. A first start without archive and Metal cache runs at 18.1 instead of 19.0 fps. `MESA_KK_PIPELINE_ARCHIVES=0` turns it off. Wine's D3D9 tests, vkd3d-proton's test suite and the D3D11 tests give the same results as before
- The development Mac is a fanless MacBook Air (Mac15,13). After a few benchmark runs in a row it throttles: Rise of the Tomb Raider's mean falls from 26 to 21–22 fps, Syria from 26 to 16–17. Comparisons need cool-down pauses. In that state, skipping the tessellator and the tessellated draws entirely gained only about 0.6 fps (22.5 instead of 21.9); rewriting the tessellator kernels is therefore not worth it for now. Also, Rise of the Tomb Raider's Metal builds after the start can overlap the benchmark; see Mesa patch 0039

UE5 with `-dx12`: for shader model 6.6, vkd3d requires 64-bit buffer atomics with all operations and compute shader derivatives. At 64 bits Metal only has `atomic_min`/`atomic_max` (buffers and textures, tested on the M3), no `add` or compare-and-swap, and no derivatives in compute shaders; SM 6.2 already fails on the denormal control. Mesa patch 0030 emulates the missing 64-bit atomics, vkd3d patches 0009–0011 report SM 6.6 and feature level 12_0 on KosmicKrisp, and with Mesa patches 0032 and 0033 UE5 renders with D3D12 (see the open items below).

## Goal

Start Windows games from Steam on Apple silicon Macs, with the same structure
as Proton on Linux: Wine + translation layers for DirectX + a bridge to the
native Steam client + the `proton` launch script.

## Architecture decisions

| Topic | Decision | Reason |
|---|---|---|
| CPU architecture | Wine as **x86_64**, running under **Rosetta 2**; 32-bit through **WoW64** (`--enable-archs=i386,x86_64`) | Windows games are x86 code. Native arm64 Wine on macOS is not supported upstream (16K pages, ABI). CrossOver and GPTK do the same. |
| Emulator | No FEX | Rosetta 2 takes that role. |
| Windows/input | `winemac.drv` instead of `winex11.drv`/`winewayland.drv` | Already exists in the Wine tree. |
| D3D9–11 | DXVK on **MoltenVK** | The only open-source option. Gaps: transform feedback, some formats; MoltenVK emulates geometry shaders with compute. |
| D3D12 | vkd3d-proton, first steps (see phase 4) | Runs on MoltenVK with compromises, untested with games so far. |
| Sync primitives | fsync through `os_sync_wait_on_address` (macOS 14.4+, Wine patch 0006), otherwise wineserver sync; ntsync off | On Linux fsync is based on `futex_waitv`, ntsync on a Linux kernel module. |
| Build | native build on macOS instead of Docker/Steam Runtime containers | The Linux container produces no Mach-O binaries. |

## Phases

### Phase 1 – Wine builds and runs (in progress)
- [x] Core submodules fetched (`wine`, `dxvk`, `vkd3d-proton`, `vkd3d`, headers, `glslang`)
- [x] Generated sources (`make_vulkan`, `make_specfiles`) and `configure` created
- [x] Proton's Wine configures for macOS x86_64 + WoW64 (minimal dependencies)
- [x] Wine compiles completely (x86_64 Unix + i386/x86_64 PE, ~22 min on Apple silicon)
- [x] Creating a prefix; 64-bit and 32-bit (WoW64) programs run under Rosetta, `notepad` opens through `winemac.drv`
- [ ] `WINEDLLOVERRIDES="mscoree,mshtml="` is required when creating the prefix, otherwise `wineboot` hangs at the Mono/Gecko dialog → move into the `proton` script (Proton does the same on Linux)

Wine changes for macOS so far (all through `#ifdef` or configure, Linux behavior unchanged):

| File | Change |
|---|---|
| `server/fsync.c`, `dlls/ntdll/unix/fsync.c` | futex syscalls only on Linux; on macOS `os_sync_wait_on_address` (Wine patch 0006) |
| `server/inproc_sync.c`, `dlls/ntdll/unix/sync.c` | `ntsync_tmp.h` only on Linux → the existing fallback applies |
| `dlls/ntdll/unix/loader.c` | `malloc.h`/`mallopt(M_PERTURB)` only with glibc |
| `dlls/ntdll/unix/signal_x86_64.c` | `set_thread_teb` only on Linux (macOS sets %gs in `init_syscall_frame`); `jmp *%rcx` instead of `jmp %rcx` |
| `dlls/ntdll/unix/system.c` | sysfs helpers for `WINE_CPU_TOPOLOGY` as stubs outside Linux |
| `dlls/amd_ags_x64/unixlib.c` | libdrm/amdgpu optional, otherwise `STATUS_NOT_SUPPORTED` |
| `dlls/win32u/opengl.c` | fshack framebuffer surfaces without EGL as inactive stubs |
| `dlls/winegstreamer/media-converter/media-converter.h` | missing `#include <pthread.h>` |
| `configure.ac` | `loader64` disabled on Darwin |
| `server/token.c` | user SID from the hardware UUID (`gethostuuid`) instead of `/etc/machine-id` |
| `include/wine/server_protocol.h` and others | regenerated with `tools/make_requests` |
- [x] x86_64 dependencies built ourselves (Homebrew no longer offers Intel bottles): MoltenVK, FreeType, GMP, nettle, GnuTLS – all in `macos/build.sh`, tarballs checked against fixed SHA-256 sums
- [x] GnuTLS: without it, certificate signature checks fail in Wine (`bcrypt: key_asymmetric_create no encryption support`), and so does HTTPS through schannel. In games this showed as `Curl error 60: Cert verify failed` (UnityTls uses the Windows certificate store and its verification). Test: `docs/macos/tls-check.c`
- [x] SDL2 (controllers)

Note on testing: `DYLD_*` variables do not survive starting SIP-protected programs (`/bin/sh`, `/usr/bin/timeout`, `/usr/bin/env`). They have to be set after such programs – `run.sh` does that itself.

### Phase 2 – Build system
- [ ] `configure.sh` / `Makefile.in`: add a `darwin` target, bypass the Docker path
- [ ] Make components that only make sense on Linux optional (FEX, parts of gstreamer, kaldi/vosk/piper, wineopenxr, vrclient)
- [ ] `install_name_tool`/rpath handling instead of `LD_LIBRARY_PATH`
- [ ] Output as a portable folder or `.app` bundle

### Phase 3 – Graphics D3D9–11

Measured (Apple M3, MoltenVK 1.4.2, Vulkan 1.3.357): MoltenVK covers Vulkan 1.3
almost completely, but required features for **DXVK 2.7.1** are missing – DXVK
rejects the device entirely:

| Missing in MoltenVK | Use in DXVK | Required from |
|---|---|---|
| `geometryShader` | geometry shaders | D3D9 baseline |
| `shaderCullDistance` | cull distances | D3D9 baseline |
| `nullDescriptor`, `robustBufferAccess2` | unbound resources | D3D9 baseline |
| `VK_EXT_depth_clip_enable` | depth clipping | all |
| `transformFeedback` | stream output | D3D11 |

Test programs: `docs/macos/mvkcheck.c` (features), `docs/macos/d3d11-nulltest.c` (unbound resources, swapchain), `docs/macos/d3d11-blendtest.c` (blending, textures, samplers, constant buffers), `docs/macos/d3d11-geomtest.c` (vertex/index buffers, reversed Z on D16/D24S8/D32/D32S8).

**DXVK changes** (active only on portability devices: `VK_KHR_portability_subset`
or driver ID `VK_DRIVER_ID_MOLTENVK` – Wine does not pass the extension on to
Windows programs; on Linux DXVK stays as strict as before):

| Feature | Workaround |
|---|---|
| `geometryShader`, `shaderCullDistance` | optional; only shaders that use them fail |
| `depthClipEnable` | approximated with `depthClampEnable = !depthClip` (as in DXVK 1.x) |
| `nullDescriptor`, `robustBufferAccess2` | `DxvkNullResources`: zero-initialized placeholders (buffers, texel views, 1D/2D/3D/cube images) per context, initialized in the init command buffer |
| `transformFeedback` | was already optional in D3D11 |

Result (Apple M3): DXVK creates a D3D11 device with **feature level 11_0**
(11_1 fails on `logicOp`, which Metal does not have). Test program
`docs/macos/d3d11-nulltest.c`: unbound textures/constant buffers read exactly 0,
120 frames through the swapchain – all passed.

**wined3d** (Wine's own D3D translation on Apple's OpenGL 4.1):
D3D9 visual tests 211,215 checks with 47 (64-bit) and 48 (32-bit) failures,
D3D11 tests 4,006 checks with 15 failures. **wined3d does not reach feature
level 11_0 on macOS** – D3D11 games need DXVK.

Wine's own D3D11 test suite says little about DXVK: it crashes in the D3D10
interop path (`ID3D10Texture3D_GetDevice`) – independently of MoltenVK.

- [ ] winevulkan → MoltenVK (needs an x86_64 build of MoltenVK)
- [ ] Build DXVK with MinGW for macOS, catch MoltenVK's gaps through configuration
- [ ] Pick test games for DX9, DX10, DX11 and record compatibility

### Phase 4 – D3D12
The choice is vkd3d-proton on MoltenVK (patches in `macos/patches/vkd3d-proton`, values from `docs/macos/vkd3dcheck.c`):
- [x] The device is created despite missing robustness2, nullDescriptor, transform feedback and texel buffer alignment; these cases only warn
- [x] MoltenVK writes empty descriptors as `nil`, and Metal reads zero. Empty vertex buffers get a zeroed stand-in buffer, because MoltenVK dereferences every buffer passed
- [x] Feature level 12_0 on MoltenVK, although sparse resources (tiled resources tier 0) and logic ops are missing; these caps stay honest
- [x] `docs/macos/d3d12-test.c`: clear, triangle, triangle with an empty vertex buffer, device with minimum feature level 12_0, present through a DXGI swapchain
- [x] Unreal Engine 5 with D3D12 (Town To City, UE 5.7, `-dx12` or no switch, since UE5 then picks D3D12 by itself): renders on KosmicKrisp. It needed feature level 12_0 (vkd3d patch 0011), SM 6.6 with 64-bit atomics (Mesa patch 0030, vkd3d patch 0009) and above all Mesa patch 0033: before, the game drew depth, GBuffer, lighting and TSR correctly, but bloom and the tonemapper read the TSR output, a 2D array with one layer, through a `texture2d` declaration, and Metal then returned the same texel for every coordinate; the image was a surface in fog color. Found with a temporary trace in KosmicKrisp and vkd3d (render targets, UAVs and SRVs read back per pass, MSL of single shaders replaced); compression, barriers, samplers, LOD and the descriptor index were ruled out. The game does not use Nanite. Low settings 22 fps in game (1710×1107). Epic 8.4 fps with warm caches (Belvau sandbox): GPU-bound, the render, RHI and submission threads mostly wait for the GPU. Per frame the GPU spends about 50 ms in the vertex stage (which on Apple GPUs includes binning), 24 ms in compute and 21 ms in fragment work for about 1,050 draws, half of them indirect; KosmicKrisp unrolls none of them and splits no render passes for them. The geometry load of the Epic settings (foliage, shadow cascades) is the cost, not a driver detour
- [x] Mesa patch 0030: 64-bit atomics on KosmicKrisp from Apple9 (M3) on. Metal only has 64-bit `max`/`min` without a return value, on buffers and on RG32Uint textures the shader reads as `ulong`; that is exactly what Nanite's visibility buffer needs. Add, and, or and xor on buffers run as two 32-bit atomics (correct value in memory, the returned old value can be torn), everything else reads and writes lane by lane of a SIMD group one after another, so it is non-atomic only between SIMD groups. R64_UINT/R64_SINT are storage images on RG32Uint. Tested with vkd3d-proton's test suite (`test_shader_sm66_64bit_atomics`: root descriptor, raw and typed tables, 96 checks passed); 64-bit atomics on groupshared memory are still missing
- [x] vkd3d patch 0009: vkd3d reports SM 6.6 on KosmicKrisp. Only float controls were missing (Apple GPUs flush FP32 denormals to zero, which is DXIL's default) and the extension for derivatives in compute shaders, which KosmicKrisp can do anyway; vkd3d already makes the same exception for older NVIDIA drivers. All SM 6.x tests of the suite pass except `test_shader_sm62_denorm` (denormals are flushed even when the shader wants to keep them) and `test_shader_sm66_is_helper_lane`. Built as a Windows program with `meson setup … -Denable_tests=true` and `ninja tests/d3d12.exe`, started with `run.sh --exec`; `VKD3D_TEST_FILTER` selects tests
- [x] vkd3d patch 0010: native 16-bit shader operations on KosmicKrisp. Apple GPUs keep FP16 denormals (measured, in both Metal's fast and precise math modes) and compute FP16 twice as fast as FP32. With this the 16-bit and SM 6.x tests run instead of being skipped, about 37 million checks, and fail only where they failed before
- [x] vkd3d patch 0011: feature level 12_0 on KosmicKrisp as on MoltenVK, although sparse residency and logic ops are missing; Unreal Engine 5 requires at least 12_0 for D3D12
- Comparison of the whole test suite before and after Mesa patch 0030 and vkd3d patch 0009 (every test that hangs for 180 s is excluded): the same five tests hang in both cases (fence waits with events registered twice and shared fences, DirectStorage decompression, a very large texel buffer, destruction notifier). New failures only in tests that were skipped before: denormals, `IsHelperLane`, sampler feedback (vkd3d reports it as soon as there are 64-bit image atomics; one check of three fails in each) and a check of undefined behavior with wrong descriptor types
- [x] SPIRV-Cross (in MoltenVK) casts alias descriptors with a C cast (`macos/patches/spirv-cross`): if the first buffer type is `Restrict`, `reinterpret_cast` lost the `__restrict`, and Metal rejected the compute shader (“casts away qualifiers”). `build.sh` passes MoltenVK its own SPIRV-Cross copy for this (`--spirv-cross-root`), because `fetchDependencies` resets MoltenVK's own
- [x] Crash in `vkQueueSubmit2` (0xc0000005) and “Invalid Resource”: MoltenVK passed all buffers with a device address to `useResources` only at the next draw; if another thread freed one of them in between, the pointer was invalid. With a residency set the list is gone (MoltenVK patch 0002). Found with a debug ntdll that prints the frame pointer chain on faults in Unix code
- [x] Empty descriptors: instead of `nil`, MoltenVK binds zeroed stand-in resources (64 KiB buffer, 1×1 texture, sampler), also for empty vertex buffers (MoltenVK patch 0003)
- [x] On MoltenVK, vkd3d turns on dxil-spirv's extended robustness (local arrays, constant tables). For threadgroup memory dxil-spirv clamps the index to the last element (`macos/patches/dxil-spirv`), because games read just past the end and Apple GPUs abort on that
- [x] SPIRV-Cross wrote stores through a pointer copy (`OpCopyObject` of an access chain) as `*_33[i] = x`, which Metal rejects (SPIRV-Cross patch 0002). Because of this Horizon Zero Dawn got no pipeline object for two compute shaders and crashed in the opening scene. Since then the opening scene, the main menu and a new game run into the game world
- [x] Horizon Zero Dawn: the characters' skin and hair appeared white. dxil-spirv also samples bindless color texture arrays with `SampleCmp`/`GatherCmp` (Vulkan ignores the depth operand of `OpTypeImage`), and SPIRV-Cross then declared the whole array as `depth2d`: every normal access in the same shader read only the red channel. Affected 198 of about 8,000 shaders in Horizon. A patch of our own kept the color declaration; since d6b093e0 SPIRV-Cross does this itself (`spvDepthCast` at the comparisons), and the patch is gone
- [x] Geometry shaders: MoltenVK now emulates them with compute stages like tessellation (MoltenVK patch 0007, `docs/macos/geometry-shaders.md`). The vertex shader runs as a kernel and writes its outputs packed into a buffer, the geometry shader runs as a kernel with one thread per primitive and invocation and writes vertices and strip indices, and a vertex shader then draws them. Direct, indexed and indirect draws, instances, invocations, strip restarts and point output; test in `macos/tests/geometry/run.sh`. Not emulated: geometry shaders together with tessellation, multiple streams and transform feedback
- [x] Ratchet & Clank: Rift Apart quit on an `ApiInformation` query (Wine patch 0003) and then reported “no graphics card”: MoltenVK gave Apple GPUs a different device ID than Wine's registry entry for the display device (MoltenVK patch 0004). Now the launcher starts
- [x] Tessellation pipelines failed because SPIRV-Cross cannot handle `Component` decorations in MSL tessellation stages. In pipelines with tessellation on MoltenVK, vkd3d spreads every component to a location of its own (`64·component + row`), from the vertex shader to the pixel shader (vkd3d patch 0007)
- [x] Tessellation vertex shaders wrote packed outputs through a `device` pointer although they are local (SPIRV-Cross patch 0003)
- [x] Pixel shaders that write `float4` to an integer render target (D3D allows this with an undefined result) made Metal reject the whole pipeline. MoltenVK now leaves such outputs out (MoltenVK patch 0005)
- [ ] Ratchet & Clank: after “Play” all pipelines are created, then all threads hang on Wine's `vectored_handlers_section` (“blocked by 0000”, the lock has no owner anymore). `crs-client.dll` (crash reporter) is a required import and cannot be turned off

### More games from the smoke test
- [x] Foundation requires OpenGL 4.3, macOS has at most 4.1: it now runs with OpenGL 4.6 through Zink on KosmicKrisp (Mesa as the Windows `opengl32.dll`, 64 and 32 bit; Zink on MoltenVK does not work, `nullDescriptor` is missing). The app turns Zink on for Foundation by itself. For 4.x, Zink lacked only `GL_ARB_texture_buffer_object_rgb32` (no RGB32 texel buffers in Metal); run.sh reports the extension through `MESA_EXTENSION_OVERRIDE`
- [x] Games on exFAT drives: macOS puts a `._` file for file attributes next to every file steamcmd writes, thousands per game. Foundation read them as localization and crashed. The runner deletes them before every start (milliseconds)
- [ ] Rogue Tower (Unity, 32-bit) crashes on start in Wine's exception handling (“Exception frame is not in stack limits”). The cause is an access violation before that, every time at the same place: a 32-bit thread executes Wine's 64-bit entry from wow64cpu (`syscall_32to64` or `unix_call_32to64`, reached through the far jump `ljmp` of the syscalls) in 32-bit mode and reads `cs32_sel(%rip)` there as the absolute address `0x5ecd`. Not the cause: suspend signals (none during the crash), races when suspending and resuming (a stress test with 200,000 cycles passes), Mono's JIT (a test with freshly written code passes). With `GC_DONT_GC=1` Unity gets further but later crashes the same way. Right before, wow64 sets the 32-bit context for window callbacks (`NtSetInformationThread`, class 29 `ThreadWow64Context`, twice without a query in between); that is the next lead. The return address on the stack points into the 32-bit stub of `NtQueryPerformanceCounter`, so the jump comes the normal way `__wine_syscall` → BOP thunk; the thunk is intact at the crash (`ljmp *[…]`, far pointer `syscall_32to64:0x2b`), but Rosetta does not switch to 64-bit mode on this far jump. A stress test with 22 million syscalls with constantly new threads (one LDT entry each) and one with 256 MB of freshly executed code do not reproduce it. A candidate for a bug report to Apple (Rosetta)
- If games are started from an app other than MacProton (for example from a terminal or Claude Code), macOS asks on the first access to a recording device for microphone access for that app. Games that query recording devices at start (FMOD as in Dead Island, Unreal as in Devolverland Expo) hang until someone answers. MacProton itself declares no microphone use, macOS refuses there without asking, and the games keep running
- [x] `macos/check-shaders.sh`: compiles all shaders MoltenVK dumped during a game (`MVK_CONFIG_SHADER_DUMP_DIR`) with the Metal compiler and lists what Metal rejects. This way translation errors show for all shaders of a game without reaching every effect in the game
- [x] `macos/smoke-test.py`: starts installed games from the MacProton library one after another unattended, sets up the prefix and install scripts like the app, and records in `report.md` whether a window and an image appear, whether the game crashes, loses the device, pipelines fail or Metal rejects shaders (with `check-shaders.sh`). Does not click through menus; a regression test after runtime changes
- [x] Black game world in Unreal 4 games (Medieval Dynasty with D3D11): Unreal renders the tonemapper's color grading LUT with a geometry shader that routes every triangle into a slice of a 3D texture. MoltenVK left it out, everything ended up in slice 0, and the image turned black after tonemapping. If a geometry shader only passes triangles through and takes the layer from an input, MoltenVK now writes the layer in the vertex shader (MoltenVK patch 0006)
- [x] Medieval Dynasty with D3D12 lost the device a minute or two after loading the game world (“Internal Error” 0x10d, without an encoder). Narrowed down through Unreal console variables to `r.DFShadowScatterTileCulling`: the distance field shadows distribute objects onto light tiles with draws without a render target. vkd3d begins such passes with the largest render area and 2048 layers (`maxFramebufferLayers`), MoltenVK passed this layer count to Metal, and the GPU aborts the pass. Without attachments MoltenVK no longer sets layers (MoltenVK patch 0008); `docs/macos/d3d12-uavcount.c` reproduces the case. Medieval Dynasty now also runs into the game world with D3D12
- [x] Typed buffers outside the view: vkd3d turns such indices into `0xFFFFFFFF` and relies on Vulkan discarding the access. Metal does not; SPIRV-Cross now checks the bounds of texel buffer reads, writes and atomics (SPIRV-Cross patch 0004)
- Checked and dropped: a stand-in texture per texture type for empty descriptors (shaders read the same heap slot as 2D, 3D, cube and texel buffer) changed nothing about the device loss
- [ ] Test games with pure D3D12; still missing on MoltenVK are stream output and sparse resources. MoltenVK `main` has `vkCmdDrawIndirectCount` and `VK_EXT_depth_clip_enable` by now; the geometry shader emulation reads the count buffer too

### Display
- [x] **Upscaling** (setting in MacProton, “Display”): without Retina mode, windows and swapchains are sized in points, and macOS doubles every frame bilinearly. With `MVK_CONFIG_UPSCALING=metalfx` the game keeps rendering into its images, and MoltenVK upscales them to the display's pixels with MetalFX Spatial on present (MoltenVK patch 0009). MetalFX is loaded only at runtime. “Pixel-exact” sets `MVK_CONFIG_SWAPCHAIN_MIN_MAG_FILTER_USE_NEAREST`. MetalFX Temporal would need depth and motion vectors from the game and is therefore not offered

### Old games (32-bit, D3D9)
- [x] Wine patch 0007: 32-bit D3D9 games through DXVK hung on KosmicKrisp when switching to full screen. In WoW64 processes, for drivers with `VK_EXT_map_memory_placed` (KosmicKrisp yes, MoltenVK no) win32u queries its properties through the core name `vkGetPhysicalDeviceProperties2`. But its own instance for D3DKMT is a Vulkan 1.0 instance, in which Mesa only provides the `KHR` name: the call landed on NULL, in the middle of `D3DKMTOpenAdapterFromLuid`, and left its `pthread_once` unfinished. On the next mode change win32u took the display lock, ran into the same `pthread_once`, macOS aborted the recursion, and the lock stayed held forever. Now win32u uses the `KHR` name, as the branch below does. Test program `docs/macos/d3d9-fullscreen.c` (full-screen device at 640×480 as old games use); found through Wine's 32-bit D3D9 visual tests, which hung there
- Wine's D3D9 visual tests (32-bit) through DXVK: on KosmicKrisp 209,676 checks with 779 failures, mostly with fog (`fog_with_shader_test` with vertex shaders that write no `oFog`, and `test_fog`), texture transforms, format conversions, point sizes and ATI's Fetch4; on MoltenVK DXVK aborts early with an assertion (Metal cannot turn off primitive restart). For old D3D9 games KosmicKrisp is therefore the better driver
- Tessellation in Rise of the Tomb Raider: KosmicKrisp ends the render encoder for every tessellated draw (the compute stages VS, TCS, counting, prefix sum and tessellator run in a compute encoder) and reloads all render targets afterwards. Measured 85–105 render encoders per frame, 5–14 of them because of tessellation. A remedy would be running the tessellation stages in the render encoder (tile shaders) or deferring the encoding of a render pass; both are larger rewrites
  Measured in November 2026 with a temporary switch in KosmicKrisp (Spine of the Mountain, warm caches): normal 31.7 fps, without tessellated draws 37.0, with tessellation compute and splits but without drawing 32.1, with only the splits 35.6. The splits cost about 1 ms per frame (nothing measurable in Geothermal Valley), the compute stages about 3 ms (4–5 ms in Geothermal Valley), drawing the tessellated geometry hardly anything. The render thread spends almost no CPU on tessellation, so its cost is on the GPU: per draw five small dispatches, each waiting for the previous one, VS and TCS run once per index rather than per vertex, and Mesa's D3D11 reference tessellator (shared with Asahi) handles a patch on one thread. Deferring render passes would therefore gain little; faster tessellation needs those kernels rewritten. patch 0005's light barriers gave 2 % at most here (32.5 instead of 31.8 fps)

### Synchronization
- [x] **fsync on macOS** (Wine patch 0006): threads wait in shared memory instead of through requests to the wineserver. macOS 14.4 can wait on an address across processes with `os_sync_wait_on_address(_with_timeout)` and the flag `SHARED`; that suffices for one object. For `futex_waitv` (several objects) a thread sleeps on one of 48 sequence numbers in the reserved first slots, picked by thread ID (`tid >> 2`, thread IDs are multiples of 4). For this the slots are 32 instead of 16 bytes; the last 8 bytes count such waiters (lower 16 bits) and mark their sequence numbers, and `futex_wake` increments the marked ones and wakes them. `run.sh` sets `WINEFSYNC=1`, `WINEFSYNC=0` switches back
- Measured: event ping-pong between threads 6 instead of 20 µs, across processes 8 µs. Green Hell (KosmicKrisp) about 10 % faster, Rise of the Tomb Raider equally fast
- A sleeping thread on macOS now and then misses its wake-up or does not get to run for seconds; with fsync, Rise of the Tomb Raider therefore hung for 0.5 to 4 s in about every second benchmark. So no wait sleeps longer than 250 ms at a time; after that the caller checks its objects again as after a spurious wake-up. Since then no frame over 100 ms in 14 runs except the cold start pattern in the Geothermal Valley (four frames around 500 ms in the first run after a pause), which also occurs without fsync. Synthetic tests (semaphore load, timers, wake-ups from the server under full load) lose no wake-up; the cause is open
- `docs/macos/synctest.c` checks the sync objects with and without fsync: ping-pong, semaphores, mutexes, wait-any/all, APCs, timeouts, abandoned mutexes, `SignalObjectAndWait`, waits longer than 250 ms and process boundaries

### Loading times
- [x] **MSL cache** (MoltenVK patch 0010): MoltenVK translated every shader from SPIR-V to MSL again on every start. That runs under Rosetta and cost Horizon Zero Dawn about 50,000 translations of 17 to 45 ms each on seven threads while loading. macOS caches the Metal part itself (`$(getconf DARWIN_USER_CACHE_DIR)org.winehq.wine/com.apple.metal`). With `MVK_CONFIG_SHADER_CACHE_DIR`, MoltenVK appends every translation to a file, keyed by the SPIR-V code and the serialized configuration the pipeline requests. Later starts and later pipelines in the same start take the MSL from the file. `run.sh` puts the cache in `$WINEPREFIX/moltenvk-cache`; the file is valid only for the same MoltenVK build (Mach-O UUID) and the same device, and MoltenVK deletes files of other builds. Set empty, the variable turns the cache off
- Measured with Horizon Zero Dawn (Apple M3, “Continue” up to the game world): after an update of vkd3d-proton and MoltenVK (all caches invalid) about 27 minutes for 24,000 pipelines; with a warm Metal cache but without the MSL cache 140 s; with the MSL cache 35 s. The MSL cache takes 144 MB
- [ ] The first start after a runtime update stays long: Horizon then builds all of the game's pipelines again, and the Metal compiler occupies all cores

- [x] **Game Mode**: macOS turns it on only for processes whose app bundle is in the “Games” category (`LSApplicationCategoryType`), and only while the game window is in front; GamePolicyAgent looks up the process's bundle record for this (`bundleRecordForAuditToken`). The Info.plist embedded in Wine's loader does not count. `build.sh` therefore creates `lib/wine/x86_64-unix/Wine.app` (a copy of the loader and Wine's Info.plist, now with the category “Games” and `GCSupportsGameMode`), ntdll starts Windows programs from this bundle, and its loader finds `ntdll.so` three folders up (Wine patch 0005). `LSUIElement` stays, so background processes get no Dock icon

### Phase 5 – Steam integration
- [x] `lsteamclient`: there already is an `__APPLE__` branch in `lsteamclient/unixlib.cpp` that loads `steamclient.dylib`. Checked: the macOS Steam client ships `steamclient.dylib` as a universal binary (x86_64 + arm64), so the Rosetta Wine process can load it.
- [x] `Steam_IsKnownInterface` and `Steam_NotifyMissingInterface` are missing in the macOS dylib → loaded optionally on macOS (fallback: `false` or do nothing), so `steamclient_init` does not abort
- [x] Build lsteamclient and steam_helper (`steam.exe`) for macOS – `macos/makedep-module.py` replaces the GNU-sed-based makedep rules
- [x] `steamclient64.dll`/`steamclient.dll` in the prefix are stub DLLs (`macos/steamclient-stub.py`) that only export the names from `lsteamclient.spec`: Mac Steam ships no Windows versions, and Wine's loader redirects the exports to lsteamclient with trampolines. Copies of `lsteamclient.dll` do not work reliably – Wine then takes the copy for lsteamclient itself and redirects to itself (endless loop in `CreateInterface`)
- [x] **Cult of the Lamb** (Unity, D3D11) runs with Steamworks through the running Mac Steam client up to its main menu, 60 FPS (Apple M3) – started through `macos/run.sh`, also with a fresh prefix from `macos/build.sh`

Changes for this:

| File | Change |
|---|---|
| `lsteamclient/unix_private.h` | `stdlib.h`/`wchar.h` before `winbase.h`, which blocks `wcsncpy` and co. with `__WINESRC__` (the macOS SDK loads `wchar.h` later than glibc) |
| `lsteamclient/unixlib.cpp` | `(std::max)` against Wine's `max()` macro |
| `lsteamclient/unix_steam_input_manual.cpp` | VK → macOS key codes (`kVK_*`) for ISteamHTMLSurface |
| `dxvk/src/dxvk/dxvk_presenter.cpp` | MoltenVK: request `VK_PRESENT_SCALING_STRETCH`, otherwise `VK_SUBOPTIMAL_KHR` on every present and swapchain recreation in an endless loop (flicker) |
| `wine/dlls/win32u/{vulkan,opengl}.c` | Proton's full-screen hack off by default on macOS (`WINE_DISABLE_FULLSCREEN_HACK=0` turns it on): with it the image does not reach the window, only the background color was visible |
- [ ] Steam for macOS offers no compatibility tools → start through a launcher of our own, or Windows Steam in the prefix as a stopgap
- [ ] `vrclient_x64`, `wineopenxr`: leave out on macOS

### Phase 6 – `proton` launch script
Linux assumptions in the `proton` script:
- `LD_LIBRARY_PATH` (line ~48) → `DYLD_FALLBACK_LIBRARY_PATH`
- `libdl.so.2`, `libGLX_nvidia.so.0` (~415–460) → skip on macOS
- `/proc/modules`, `/proc/sys/vm/max_map_count` (~1421, ~2012) → skip
- `WINEFSYNC`/ntsync logic (~1766–1784) → ntsync off on macOS; `run.sh` sets `WINEFSYNC=1`
- Remove Steam Runtime/pressure-vessel assumptions

### Phase 7 – Distribution through GitHub
Goal: users download a release from GitHub, unzip it and start it – without
Xcode, Homebrew or a build of their own.

- [x] Releases are built locally with `macos/release.sh` and published as
      assets on **GitHub Releases**
- [ ] **GitHub Actions** on macOS runners (`macos-14`/Apple silicon) to build
      the package reproducibly
- [x] **No runtime dependency on Homebrew**: all x86_64 dylibs (FreeType,
      GnuTLS, MoltenVK, SDL2 …) are in the package, their paths rewritten to
      `@rpath`/`@loader_path` with `install_name_tool`
- [x] A single self-contained package (`MacProton.app` with the runtime in
      the Proton layout `files/bin`, `files/lib`, `files/share`)
- [ ] **Code signing + notarization** (Developer ID); without it Gatekeeper
      blocks the downloaded binaries. For the unsigned builds the README
      documents allowing the app once and `xattr -dr com.apple.quarantine`
- [x] Rosetta check on the first start (the app offers `softwareupdate --install-rosetta`)
- [x] Versioning and a checksum (`.zip.sha256`) per release
- [x] Licenses: the license texts of everything shipped are in
      `macos/licenses` and in the app (`macos/collect-licenses.sh`).
      **D3DMetal must not be shipped** – if ever used, only as an optional
      import from a local GPTK installation

### Open items (to-do)

- [x] **Save sync (Steam Cloud)**, implemented in MacProton (before the start, can be turned off; backups under `~/Library/Application Support/MacProton/save-backups`). Open: check that Mac Steam really uploads after the game ends. Original analysis: games with Auto-Cloud have separate save paths per operating system (`ufs/rootoverrides` in the app info). Mac Steam syncs only the Mac path (for example `~/Library/Application Support/Massive Monster/Cult Of The Lamb/saves`), while the Windows version saves in the prefix (`AppData/LocalLow/...`). Plan: if there is a Windows and a macOS rule, MacProton redirects the prefix folder to the Mac path – after backing up both sides. Games with ISteamRemoteStorage should already sync through lsteamclient (untested). Pure Windows games with Auto-Cloud: open.
- [x] **Steam Cloud sync for Windows games** (MacProton): Steam for macOS lists the Auto-Cloud files of games without a Mac version (`platformstosync2` = Windows) and never downloads or uploads them; this affects for example Raft, Horizon Zero Dawn and Medieval Dynasty. steamcmd does not help: `app_run` does not sync before the start, and its compatibility layer is disabled on the Mac. The cloud methods of the Web API (`ICloudService`) need a publisher OAuth access per app. MacProton therefore speaks Steam's client protocol over WebSocket (`SteamConnection.swift`): sign-in by QR code with the Steam app (`IAuthenticationService`, platform “Steam client”), logon with the refresh token and a login ID of its own so that Mac Steam stays signed in, then `Cloud.GetAppFileChangelist`, `ClientFileDownload` and for uploading `BeginAppUploadBatch`, `ClientBeginFileUpload`, HTTP PUT, `ClientCommitFileUpload`, `CompleteAppUploadBatchBlocking`. Never disconnect with `ClientLogOff`, that revokes the token. On upload Steam checks the Auto-Cloud rules (EResult 42) and skips known content (EResult 29). `CloudSync.swift` compares the SHA-1 of cloud, prefix and last sync: download before the start, upload after the end (`wineserver -w`), the user decides conflicts, and whatever is replaced lands in `save-backups/<AppID>/…-cloud-sync`. MacProton deletes in the cloud only if the sync before the start succeeded. Tested with Raft: 17 cloud files downloaded into the prefix; uploading and deleting with a test file
- [x] **Controller support:** SDL2 2.32.10 as an x86_64 dependency, Wine configured with SDL (winebus also has the IOKit HID backend). Tested with an Xbox Wireless Controller over Bluetooth: all buttons, triggers, the d-pad, both sticks and stick clicks (LS/RS, also at once) arrive through XInput (`docs/macos/xinput-check.c`). Open: PlayStation/Switch controllers untested.
- [x] **Library sync** (MacProton app): `licenses_print` → abbreviated packages through `package_info_print` → `app_info_print` per app in an interactive steamcmd session (queries chained on the command line are answered asynchronously by steamcmd, which prints only the first). Filter: type `game` with a Windows executable; package 0 (Steam's tools/servers) excluded. Test account: 312 apps → 70 Windows games, 28 of them also native for Mac, ~26 s.
- [x] Detect and mark games with anti-cheat (EasyAntiCheat, BattlEye) and third-party launchers (Ubisoft Connect, EA app) (executables, Steam Deck test results, game folder after installation)
- [x] **Steam overlay:** Steam's overlay for macOS games (`gameoverlayrenderer.dylib`, a universal binary with Metal and AppKit hooks) also works in Wine games. `run.sh` loads it through `DYLD_INSERT_LIBRARIES` (SIP removes the variable when `/bin/bash` starts, so the script sets it itself); Steam then starts `gameoverlayui` for the game, Shift+Tab opens it, and the games' store and profile pages appear in it. Can be turned off in Settings (`MACPROTON_STEAM_OVERLAY=0`). The overlay writes into the drawable as if it had 8 bits per channel; with the overlay loaded, MoltenVK therefore copies 10-bit swapchains (Unreal with D3D12) into a BGRA8 drawable (MoltenVK patch 0011)

## Disk space

The development Mac had only about 37 GB free at the start. A complete Proton
build (all submodules, all architectures) needs much more, so only the core
components are fetched and built.

## Building and starting

```bash
# once
brew install bison flex mingw-w64 autoconf automake meson ninja glslang cmake pkgconf

# build everything (Wine, MoltenVK, FreeType, DXVK 64/32-bit, lsteamclient, steam.exe)
macos/build.sh ../build-macos

# start a game (Steam must be running and signed in)
../build-macos/dist/run.sh 1313140 /path/to/CultOfTheLamb "Cult Of The Lamb.exe"
```

`build.sh` skips finished steps (stamps in `BUILD_DIR/stamps`), and
`DEPS_SRC` points to existing MoltenVK/FreeType clones. The result is
`BUILD_DIR/dist` with `files/` in the Proton layout and the launcher `run.sh`,
which creates a prefix per app ID under
`~/Library/Application Support/MacProton/prefixes`, sets up DXVK and the
`steamclient` copies and starts the game through `steam.exe`.

Pitfalls the scripts handle:
- `configure` needs `--build/--host=x86_64-apple-darwin`, otherwise it detects `aarch64` on Apple silicon
- Run `make` natively, not with `arch -x86_64` (otherwise the compilers run under Rosetta)
- Create Wine's generated files beforehand: `make_vulkan`, `make_specfiles`, `make_requests`, `autoreconf`
- Restrict `pkg-config` to the x86_64 dependencies (`PKG_CONFIG_LIBDIR`), otherwise it finds arm64 Homebrew libraries
