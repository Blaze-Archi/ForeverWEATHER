    // 1.0 shelter grid (included inside a shader's cbuffer; functions in rp_shelter.h.hlsl): roof height (world z,
    // -100000 = open sky) over 9 x 9 upward ray casts around the camera, row by row, 4 per vector
    uniform float4 rpShelter0;  uniform float4 rpShelter1;  uniform float4 rpShelter2;  uniform float4 rpShelter3;
    uniform float4 rpShelter4;  uniform float4 rpShelter5;  uniform float4 rpShelter6;  uniform float4 rpShelter7;
    uniform float4 rpShelter8;  uniform float4 rpShelter9;  uniform float4 rpShelter10; uniform float4 rpShelter11;
    uniform float4 rpShelter12; uniform float4 rpShelter13; uniform float4 rpShelter14; uniform float4 rpShelter15;
    uniform float4 rpShelter16; uniform float4 rpShelter17; uniform float4 rpShelter18; uniform float4 rpShelter19;
    uniform float4 rpShelter20;
    uniform float4 rpShelterG; // xy world position of the centre sample, z spacing (m), w 1 = valid
