#pragma multi_compile _ _MAIN_LIGHT_SHADOWS
#pragma multi_compile _ _MAIN_LIGHT_SHADOWS_CASCADE
#pragma multi_compile _ _MAIN_LIGHT_SHADOWS_SCREEN

#pragma multi_compile _ _ADDITIONAL_LIGHTS
#pragma multi_compile _ _ADDITIONAL_LIGHT_SHADOWS

#ifndef TOON_SHADING_FUNCTIONS
#define TOON_SHADING_FUNCTIONS

#ifndef SHADERGRAPH_PREVIEW
struct SurfaceVariables
{
    float3 normal;
    float3 view;
    float diffuseLightingOffset;
    float specularThreshold;
    float specularIntensity;
    float rimThreshold;
    float rimIntensity;
    float rimPower;
    float rimCurveFactor;
};

float CalculateSpecular(float3 lightDirection, float3 viewDirection, float3 surfaceNormal, float diffuse, float threshold, float intensity)
{
    if (intensity <= 0)
        return 0;
    if (threshold >= 1)
        return 0;
    
    float3 halfVector = SafeNormalize(lightDirection + viewDirection);
    float primitiveSpecular = saturate(dot(surfaceNormal, halfVector));
    
    float specular = step(threshold, primitiveSpecular);
    specular *= pow(intensity, 2);
    
    specular *= (diffuse > 0); 
    
    return specular;
}

float CalculateRim(float3 viewDirection, float3 surfaceNormal, float diffuse, float threshold, float intensity, float rimPower, float rimCurveFactor)
{
    if (intensity <= 0)
        return 0;
    if (threshold >= 1)
        return 0;
    
    float primitiveRim = 1 - saturate(dot(viewDirection, surfaceNormal));     
    primitiveRim = pow(abs(primitiveRim), rimPower);
    primitiveRim *= lerp(1.0, diffuse, rimCurveFactor); 
    
    float rim = step(threshold, primitiveRim); 
    rim *= pow(intensity, 2);
    
    rim *= (diffuse > 0);
    
    return rim;
}

float3 CalculateToonShading(Light l, SurfaceVariables s, float minimumLight)
{
    float diffuse = saturate(dot(s.normal, l.direction) + s.diffuseLightingOffset);
    float attenuation = l.distanceAttenuation * l.shadowAttenuation;  
    
    attenuation = saturate(attenuation); 
    diffuse *= attenuation;  
    
    float lighting = step(0.0001, diffuse); 
    lighting = clamp(lighting, minimumLight, 1.0);

    float specular = CalculateSpecular(l.direction, s.view, s.normal, diffuse, s.specularThreshold, s.specularIntensity);
    float rim = CalculateRim(s.view, s.normal, diffuse, s.rimThreshold, s.rimIntensity, s.rimPower, s.rimCurveFactor);
    
    float addOn = max(specular , rim);
    lighting += addOn;
    
    return l.color * lighting;
}
#endif

void LightingToonShaded_float(
    float3 Position,
    float3 Normal,
    float3 View,
    float DiffuseLightingOffset,
    float MinimumDiffuseMainLight,
    float SpecularThreshold,
    float SpecularIntensity,
    float RimThreshold,
    float RimIntensity,
    float RimPower,
    float RimCurveFactor,
    out float3 Color
)
{
#if defined(SHADERGRAPH_PREVIEW)
    Color = float3(0.5f,0.5f,0.5f);
#else
    SurfaceVariables s;
    s.normal = normalize(Normal);
    s.view = SafeNormalize(View);
    s.diffuseLightingOffset = DiffuseLightingOffset;
    s.specularThreshold = SpecularThreshold;
    s.specularIntensity = SpecularIntensity;
    s.rimThreshold = RimThreshold;
    s.rimIntensity = RimIntensity;
    s.rimPower = RimPower;
    s.rimCurveFactor = RimCurveFactor;
    
    Color = float3(0.0f, 0.0f, 0.0f);
    
    #if defined (_USEMAINLIGHT)
        Light mainLight;
        
        #if defined (_USEMAINLIGHTSHADOWS)
            #if defined(_MAIN_LIGHT_SHADOWS_SCREEN)
                float4 shadowCoord = ComputeScreenPos(TransformWorldToHClip(Position));
            #else 
                float4 shadowCoord = TransformWorldToShadowCoord(Position);
            #endif
            
            mainLight = GetMainLight(shadowCoord);
        #else
            mainLight = GetMainLight();
        #endif
        
        Color += CalculateToonShading(mainLight, s, MinimumDiffuseMainLight);
    
#endif
    
    #if defined(_USEADDITIONALLIGHTS) && defined(_ADDITIONAL_LIGHTS)

    int pixelLightCount = GetAdditionalLightsCount();

    for (int i = 0; i < pixelLightCount; i++)
    {
        #if defined(_USEADDITIONALLIGHTSSHADOWS) && defined(_ADDITIONAL_LIGHT_SHADOWS)
            Light additionalLight = GetAdditionalLight(i, Position, 1);
        #else
            Light additionalLight = GetAdditionalLight(i, Position);
        #endif

        
        Color += CalculateToonShading(additionalLight, s, 0);
    }

#endif
#endif
}
#endif