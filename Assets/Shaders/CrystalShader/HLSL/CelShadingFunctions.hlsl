#pragma multi_compile _ _MAIN_LIGHT_SHADOWS
#pragma multi_compile _ _MAIN_LIGHT_SHADOWS_CASCADE
#pragma multi_compile _ _MAIN_LIGHT_SHADOWS_SCREEN

#pragma multi_compile _ _ADDITIONAL_LIGHTS
#pragma multi_compile _ _ADDITIONAL_LIGHT_SHADOWS

#ifndef CEL_SHADING_FUNCTIONS
#define CEL_SHADING_FUNCTIONS

#ifndef SHADERGRAPH_PREVIEW
struct SurfaceVariables
{
    float3 normal;
    float3 view;
    float lightingBands;
    float lightingBandsBias;
    float powerShift;
    float highlightThreshold;
    float hightlightIntensity;
    float specularThreshold;
    float specularIntensity;
    float rimThreshold;
    float rimIntensity;
    float rimPower;
    float rimCurveFactor;
};
    
float PlaceLightingInBand(float diffuse, float lightingBands, float lightingBandsBias, float lowestLightingBandValue)
{
    lightingBands = max(lightingBands, 1.0); //Keep at least 1 band
    
    float floorValue = floor(diffuse * lightingBands) / lightingBands; //Eg. if there are 4 bands, values used are 0, 0.25, 0.5 and 0.75
    float ceilValue = ceil(diffuse * lightingBands) / lightingBands; //Eg. if there are 4 bands, values used are 0.25, 0.5, 0.75 and 1
    
    //Lerp the band value according to bias
    float bandedValue = lerp(floorValue, ceilValue, lightingBandsBias);
    
    bandedValue = lerp(lowestLightingBandValue, 1.0, bandedValue); //Remapping using the lowestLightingBandValue
    
    bandedValue *= diffuse > 0; //Darken darkSide Pixels
    
    return bandedValue;
}

float CalculateHighlight(float diffuse, float threshold, float intensity)
{
    //Use guard clauses to avoid unnecessary calculations and make an early return, Intensity and Threshold are not Per-Pixel (Uniform). No performance cost on 'If' branches
    if(intensity <= 0) 
        return 0;
    if (threshold >= 1) 
        return 0;
    
    float highlight = step(threshold, diffuse) * intensity; //Diffuse must be greater than threhsold
    highlight *= (diffuse > 0); //Do not produce highlight where diffuse = 0
    
    return highlight;
}

float CalculateSpecular(float3 lightDirection, float3 viewDirection, float3 surfaceNormal, float diffuse, float attenuation, float bandedLighting, float threshold, float intensity)
{
    if (intensity <= 0)
        return 0;
    if (threshold >= 1)
        return 0;
    
    //Blinn-Phon aproximation for specular lighing
    //Not exaclty phisically accurate but reduces computational power usage
    //It is not necessary to use a shininess constant due to this being a stylized shader (no need for continous specular)
    float3 halfVector = SafeNormalize(lightDirection + viewDirection);
    float primitiveSpecular = saturate(dot(surfaceNormal, halfVector));
    
    float specular = step(threshold, primitiveSpecular) * intensity; //Only Enlighten parts where the primitive specular is over the threshold
    
    #if defined(_SPECULARMODULATIONMODE_ATTENUATION)
            specular *= attenuation;     //Multiply with attenuation if attenuation dependant
    #elif defined(_SPECULARMODULATIONMODE_BAND)
            specular *= bandedLighting; //Multiply with banded lighting so specular is influenced by the light band it belongs (more realistic look). No multiplication gives a more garish look
    #endif
    
    specular *= (diffuse > 0); //Do not produce specular lighting where diffuse = 0 (Shadowed or dark parts)
    
    return specular;
}

float CalculateRim(float3 viewDirection, float3 surfaceNormal, float diffuse, float attenuation, float bandedLighting, float threshold, float intensity, float rimPower, float rimCurveFactor)
{
    if (intensity <= 0)
        return 0;
    if (threshold >= 1)
        return 0;
    
    //Produce a sort of simplified fresnel effect (using linear gradient) accross the surface of the object
    float primitiveRim = 1 - saturate(dot(viewDirection, surfaceNormal)); //Primitive rim is also a gradient     
    primitiveRim = pow(abs(primitiveRim), rimPower);
    primitiveRim *= lerp(1.0, diffuse, rimCurveFactor); //Give rim a curvature/nail shape (Thick on center, narrow on sides) using the diffuse. Note: Can also use the attenuation instead of the diffuse
    
    //Exact same logic as specular
    float rim = step(threshold, primitiveRim) * intensity; 

    #if defined(_RIMMODULATIONMODE_ATTENUATION)
            rim *= attenuation;     //Multiply with attenuation if attenuation dependant
    #elif defined(_RIMMODULATIONMODE_BAND)
            rim *= bandedLighting; //Multiply with banded lighting so specular is influenced by the light band it belongs (more realistic look). No multiplication gives a more garish look
    #endif
    
    rim *= (diffuse > 0); //Do not produce rim lighting where diffuse = 0 (Shadowed or dark parts)
    
    return rim;
}

float3 CalculateCelShading(Light l, SurfaceVariables s, float lowestLightingBandValue, float minimumLight)
{
    float diffuse = saturate(dot(s.normal, l.direction));
    float attenuation = l.distanceAttenuation * l.shadowAttenuation;  
    
    attenuation = saturate(attenuation); 
    //Important to saturate attenuation before multiplying with diffuse
    //Otherwise, if attenuation (specifically distance Attenuation) goes over 1 (surface very close to light source), diffuse * attenuation can go over 1, increasing the number of light bands
    //PlaceLightingInBand(..) expects a 0 - 1 lighting input
    
    diffuse *= attenuation;  
    float bandedLighting = PlaceLightingInBand(diffuse, s.lightingBands, s.lightingBandsBias, lowestLightingBandValue); //Place Lighting in bands
         
    //We can apply a minimum light(to enlighten darkSide pixels) by using a simple clamp and knowing the lowest band value is lowestLightingBandValue
    bandedLighting = clamp(bandedLighting, lowestLightingBandValue * minimumLight, 1.0);
    
    //AddOn Calculations
    float highlight = CalculateHighlight(diffuse, s.highlightThreshold, s.hightlightIntensity);
    float specular = CalculateSpecular(l.direction, s.view, s.normal, diffuse, attenuation, bandedLighting, s.specularThreshold, s.specularIntensity);
    float rim = CalculateRim(s.view, s.normal, diffuse, attenuation, bandedLighting, s.rimThreshold, s.rimIntensity, s.rimPower, s.rimCurveFactor);
    
    //Find the max value among the three AddOns(Highligh, Specular and Rim), as we dont want overlapping AddOns in each pixel, only the most intense one
    float addOn = max(highlight, max(specular, rim));
    bandedLighting += addOn; //Add to the bandedLighting
    
    //Power the lighting to get a nice effect (If PowerShift < 1, enlighten and uniformize lighting, if PowerShift > 1, darken all light but stand out addOns)
    bandedLighting = pow(abs(bandedLighting), s.powerShift); //Use abs only to avoid console warnings
    
    return l.color * bandedLighting;
}
#endif

void LightingCelShaded_float(
    float3 Position,
    float3 Normal,
    float3 View,
    float LightingBands,
    float LightingBandsBias,
    float MainLightLowestBandValue,
    float AdditionalLightsLowestBandValue,
    float MinimumMainLight,
    float PowerShift,
    float HightlightThreshold,
    float HightlightIntensity,
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
    s.lightingBands = LightingBands;
    s.lightingBandsBias = LightingBandsBias;
    s.powerShift = PowerShift;
    s.highlightThreshold = HightlightThreshold;
    s.hightlightIntensity = HightlightIntensity;
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
        
        Color += CalculateCelShading(mainLight, s, MainLightLowestBandValue, MinimumMainLight);
    
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

        
        Color += CalculateCelShading(additionalLight, s, AdditionalLightsLowestBandValue, 0);
    }

#endif
#endif
}
#endif