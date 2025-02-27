#version 120


//----------------------------------------------------------------------------
// Varyings

varying vec2 texcoord;
varying vec3 lightVector;
varying vec3 lightColor;
varying vec3 skyColor;

//----------------------------------------------------------------------------
// Uniforms

uniform sampler2D colortex0; 	// 0  - gcolor/colortex0 has its color cleared to the current fog color before rendering.
uniform sampler2D colortex1; 	// 1  - gdepth/colortex1 has its color cleared to solid white before rendering and uses a higher precision storage buffer suitable for storing depth values.
uniform sampler2D colortex2; 	// 2  - gnormal/colortex2 The rest have their color cleared to black with 0 alpha.
// uniform sampler2D colortex3; 	// 3
// uniform sampler2D colortex4; 	// 7
// uniform sampler2D colortex5; 	// 8
// uniform sampler2D colortex6; 	// 9
// uniform sampler2D colortex7; 	// 10

uniform sampler2D depthtex0; 	// Apparently contains depth info
uniform sampler2D shadowtex0;	// Contains a shadow map (rendered from sun position, need to change to eye space to use this, I think).

uniform sampler2D depthtex1;
uniform sampler2D depthtex2;

uniform sampler2D noisetex;

uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform mat4 shadowProjection;
uniform mat4 shadowModelView;

uniform vec3 cameraPosition;

// uniform int viewHeight;
// uniform int viewWidth;

// Direction of the sun (not normalized!)
// A vec3 indicating the position of the sun in eye space.
// uniform vec3 sunPosition;

//----------------------------------------------------------------------------
// Optifine Constants

// const int shadowMapResolution = 32;
// const int shadowMapResolution = 1024;
// const int shadowMapResolution = 4096;
const int shadowMapResolution = 16384;
// const int shadowMapResolution = 32768;
const float sunPathRotation = -10.0f;

const int noiseTextureResolution = 64;

//----------------------------------------------------------------------------
// Our constants

// const float shadowBias = 0.0f;
const float shadowBias = 0.001f; // Reasonable values within [0.001, 0.000001]
const float intensityAmbientCoeff = 0.2f;

//----------------------------------------------------------------------------

//============================================================================

// vec3 EyeToWorldSpace()


float GetShadow(float depth) {
	// Create a 3D vector with (screenX, screenY, depth) and rescale to [-1, 1]
    vec3 ClipSpace = vec3(texcoord, depth) * 2.0f - 1.0f;

	//
    vec4 ViewW = gbufferProjectionInverse * vec4(ClipSpace, 1.0f);
    vec3 View = ViewW.xyz / ViewW.w;
    vec4 World = gbufferModelViewInverse * vec4(View, 1.0f);
    vec4 ShadowSpace = shadowProjection * shadowModelView * World;
    vec3 SampleCoords = ShadowSpace.xyz * 0.5f + 0.5f;
    return step(SampleCoords.z - shadowBias, texture2D(shadowtex0, SampleCoords.xy).r);
}

vec3 gammaToLinearSpace(vec3 color) {
	return pow(color, vec3(2.2f));
}

vec3 gammaToGammaSpace(vec3 color) {
	return pow(color, vec3(1.0f/2.2f));
}


//============================================================================
// Youtube Tutorial 4, 5

struct Lightmap {
	float torchLightStrength;
	float skyLightStrength;
};

struct Fragment {
	vec3 albedo;
	vec3 normal;
	float emission;
	float depth;
};

vec3 calculateLighting(in Fragment frag, in Lightmap lightmap) {
	float directLightStrength = dot(frag.normal, lightVector);
	directLightStrength = max(0.0, directLightStrength);
	vec3 directLight = directLightStrength * lightColor;

	// Yes torch light power scales badly. Thats why they have
	// AdjustLightMapTorch in Tutorial 3 of that github repo
	vec3 torchColor = vec3(1.0f, 0.9, 0.8);
	vec3 torchLight = torchColor * lightmap.torchLightStrength;

	vec3 skyLight = skyColor * lightmap.skyLightStrength;

	vec3 litColor = frag.albedo * (directLight + skyLight + torchLight);
	// vec3 litColor = frag.albedo * (directLight);
	// vec3 litColor = frag.albedo * (pow(lightmap.torchLightStrength, 4));

	return mix(litColor, frag.albedo, frag.emission);
}

//============================================================================
// Youtube Tutorial 7, 8

vec4 getCameraSpacePosition(in vec2 coord, in float depth) {
	vec4 positionNdcSpace = vec4(coord.s * 2.0 - 1.0, coord.t * 2.0 - 1.0, 2.0 * depth - 1.0, 1.0);
	vec4 positionCameraSpace = gbufferProjectionInverse * positionNdcSpace;

	return positionCameraSpace / positionCameraSpace.w;
}

vec4 getWorldSpacePosition(in vec2 coord, in float depth) {
	vec4 positionCameraSpace = getCameraSpacePosition(coord, depth);
	vec4 positionWorldSpace = gbufferModelViewInverse * positionCameraSpace;
	positionWorldSpace.xyz += cameraPosition.xyz;
	return positionWorldSpace;
}

vec3 getShadowSpacePosition(in vec2 coord, in float depth) {
	vec4 positionWorldSpace = getWorldSpacePosition(coord, depth);

	positionWorldSpace.xyz -= cameraPosition;
	vec4 positionShadowSpace = shadowModelView * positionWorldSpace;
	positionShadowSpace = shadowProjection * positionShadowSpace;
	positionShadowSpace /= positionShadowSpace.w;

	positionShadowSpace.xyz = positionShadowSpace.xyz * 0.5 + 0.5;

	return positionShadowSpace.xyz;
}

mat2 getRotationMatrix(in vec2 coord) {

	// vec2 noiseTexCoord = coord * vec2(viewWidth / noiseTextureResolution, viewHeight / noiseTextureResolution); // Seems it doesn't rescale things well enough
	vec2 noiseTexCoord = vec2(mod(coord.x, noiseTextureResolution), mod(coord.y, noiseTextureResolution));
	float theta = texture2D(noisetex, noiseTexCoord).r;

	return mat2(
		cos(theta), -sin(theta),
		sin(theta), cos(theta)
	);
}

// 1 in sun. 0 in sun shadow.
float getSunVisibility(in vec2 coord, in float depth) {
	vec3 shadowCoord = getShadowSpacePosition(coord, depth);

	float visibility = 0.0;

	int kernel_radius = 3; // Could be made a const (or it could be useful for PCSS)

	mat2 rotationMatrix = getRotationMatrix(coord);
	// PCF filtering
	for (int y = -kernel_radius; y <= kernel_radius; y++) {
		for (int x = -kernel_radius; x <= kernel_radius; x++) {
			vec2 offset = vec2(x,y) / shadowMapResolution;
			offset = rotationMatrix * offset;

			float shadowMapSample = texture2D(shadowtex0, shadowCoord.xy + offset).r;

			visibility += step(shadowCoord.z - shadowMapSample, 0.0001);
		}
	}

	return visibility / pow((2 * kernel_radius + 1), 2); // Same as / 9
}

vec3 calculateLighting2(in vec2 texcoord, in Fragment frag, in Lightmap lightmap) {
	float directLightStrength = dot(frag.normal, lightVector);
	directLightStrength = max(0.0, directLightStrength);
	vec3 directLight = directLightStrength * lightColor * getSunVisibility(texcoord, frag.depth);

	vec3 torchColor = vec3(1.0f, 0.9, 0.8);
	vec3 torchLight = torchColor * pow(lightmap.torchLightStrength, 4);

	vec3 skyLight = skyColor * pow(lightmap.skyLightStrength, 2);

	vec3 litColor = frag.albedo * (directLight + skyLight + torchLight);

	return mix(litColor, frag.albedo, frag.emission);
}

//============================================================================

// This tells which gl_FragDatas we will be writing to
/* RENDERTARGETS: 0,1,2 */

void main() {
	//=================================================================
	// Youtube Tutorial 4, 5

	vec4 Color = texture2D(colortex0, texcoord);
	vec3 Albedo = gammaToLinearSpace(Color.rgb);
	float Emission = texture2D(colortex1, texcoord).a;
	vec3 Normal = texture2D(colortex2, texcoord).rgb * 2.0f - 1.0f;

	// float Depth = texture2D(depthtex0, texcoord).r;

	// Fragment frag = Fragment(Albedo, Normal, Emission, 0.0);
	Lightmap lightmap = Lightmap(texture2D(colortex1, texcoord).r, texture2D(colortex1, texcoord).g);

	// vec3 FinalColor = (calculateLighting(frag, lightmap));
	// vec3 FinalColor = gammaToGammaSpace(calculateLighting(frag, lightmap));

	//-----------------------------------------------------------------

	// The Diffuse Light Contribution
	// float DirectLightStrength = dot(Normal, lightVector);
	// DirectLightStrength = max(0.0, DirectLightStrength);

	// float AmbientLightStrength = 0.3;

	// vec3 LitColor = Albedo * (DirectLightStrength + AmbientLightStrength);

	// vec3 FinalColor = mix(LitColor, Albedo, Emission);

	//-----------------------------------------------------------------

	// gl_FragData[0] = vec4(FinalColor, 1.0f);

	//=================================================================
	// Youtube Tutorial 7

	vec3 finalComposite = texture2D(colortex0, texcoord).rgb;
	vec3 finalCompositeNormal = texture2D(colortex2, texcoord).rgb;
	float finalCompositeDepth = texture2D(depthtex0, texcoord).r;

	Fragment frag2 = Fragment(Albedo, Normal, Emission, finalCompositeDepth);

	// finalComposite = (calculateLighting2(texcoord, frag2, lightmap));
	finalComposite = gammaToGammaSpace(calculateLighting2(texcoord, frag2, lightmap));

	gl_FragData[0] = vec4(finalComposite, 1.);
	gl_FragData[1] = vec4(finalCompositeNormal, 1.);
	gl_FragData[2] = vec4(finalCompositeDepth);

	//=================================================================


	//-----------------------------------------------------------------
	//Debug

	// gl_FragData[0] = Color;
	// gl_FragData[0] = vec4(Albedo, 1.0f);
	// gl_FragData[0] = vec4(Normal, 1.0f);
	// gl_FragData[0] = vec4(Emission);

	// gl_FragData[0] = vec4(pow(texture2D(depthtex2, texcoord).r, 50));

	// gl_FragData[0] = texture2D(noisetex, texcoord);
}