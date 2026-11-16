    // 1.0 shelter grid (included inside a shader's cbuffer; functions in rp_shelter.h.hlsl): roof height (world z,
    // -100000 = open sky) over 13 x 13 upward ray casts 4 m apart around the camera, row by row, 4 per vector
    // (1.0.1: was 9 x 9, and the edge samples were stretched to infinity; see rp_shelter.h.hlsl)
    uniform float4 rpShelter0;  uniform float4 rpShelter1;  uniform float4 rpShelter2;  uniform float4 rpShelter3;
    uniform float4 rpShelter4;  uniform float4 rpShelter5;  uniform float4 rpShelter6;  uniform float4 rpShelter7;
    uniform float4 rpShelter8;  uniform float4 rpShelter9;  uniform float4 rpShelter10; uniform float4 rpShelter11;
    uniform float4 rpShelter12; uniform float4 rpShelter13; uniform float4 rpShelter14; uniform float4 rpShelter15;
    uniform float4 rpShelter16; uniform float4 rpShelter17; uniform float4 rpShelter18; uniform float4 rpShelter19;
    uniform float4 rpShelter20; uniform float4 rpShelter21; uniform float4 rpShelter22; uniform float4 rpShelter23;
    uniform float4 rpShelter24; uniform float4 rpShelter25; uniform float4 rpShelter26; uniform float4 rpShelter27;
    uniform float4 rpShelter28; uniform float4 rpShelter29; uniform float4 rpShelter30; uniform float4 rpShelter31;
    uniform float4 rpShelter32; uniform float4 rpShelter33; uniform float4 rpShelter34; uniform float4 rpShelter35;
    uniform float4 rpShelter36; uniform float4 rpShelter37; uniform float4 rpShelter38; uniform float4 rpShelter39;
    uniform float4 rpShelter40; uniform float4 rpShelter41; uniform float4 rpShelter42;
    uniform float4 rpShelterG; // xy world position of the centre sample, z spacing (m), w 1 = valid
    uniform float4 rpShelterF; // 1.0.1: x how much the camera is inside a tunnel / under a long roof (0..1, smoothed),
                               //        y the floor under the camera (world z), z / w the grid fades out between these
                               //        distances from the camera (m)
