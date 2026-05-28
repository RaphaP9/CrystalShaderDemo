#ifndef VORONOI_FUNCTIONS
#define VORONOI_FUNCTIONS

static const int VORONOI_EUCLIDEAN = 0;
static const int VORONOI_MANHATTAN = 1;
static const int VORONOI_CHEBYSHEV = 2;

struct VoronoiResult
{
    float3 featurePointPosition; // Position of the feature point
    float featurePointDistance; // Distance to closest feature point
    float3 cellColor; // Color of the contributing cell
};

struct VoronoiSettings
{
    float randomness; // Offset strength inside each cell (0 = grid, 1 = random)
    float smoothness; // Blending strength between cells
    int distanceMetric; // As defined in consts: 0 = Euclidean, 1 = Manhattan, 2 = Chebyshev
    float scale;
};

float3 HashInt3ToNormalizedFloat3_LCG(int3 input)
{
    //Classic LCG Constants
    const uint HASH_MULTIPLIER = 1664525u;
    const uint HASH_INCREMENT = 1013904223u;

    const uint BIT_MASK_24 = 16777215u; // 2^24 - 1
    const float FLOAT_NORMALIZER_24 = 16777216.0; // 2^24

    uint3 state = uint3(input);

    state = state * HASH_MULTIPLIER + HASH_INCREMENT; // First LCG step

    // Cross Component Mixing
    state.x += state.y * state.z;
    state.y += state.z * state.x;
    state.z += state.x * state.y;

    state ^= (state >> 16u); // Bit Mixing
    state = state * HASH_MULTIPLIER + HASH_INCREMENT; // Second LCG step

    state &= BIT_MASK_24; // Restrict to 24 bits before converting to float

    float3 normalizedState = float3(state) / FLOAT_NORMALIZER_24;
    
    return normalizedState;
}

float ComputeVoronoiDistance(float3 pointA, float3 pointB, int metric)
{
    float3 delta = pointA - pointB;
    float3 deltaAbs = abs(delta);

    switch (metric)
    {
        case VORONOI_EUCLIDEAN:
        default:
            return length(delta);
        case VORONOI_MANHATTAN:
            return deltaAbs.x + deltaAbs.y + deltaAbs.z;
        case VORONOI_CHEBYSHEV:
            return max(max(deltaAbs.x, deltaAbs.y), deltaAbs.z);
    }
}

VoronoiResult ComputeSimpleVoronoiF1(VoronoiSettings settings, float3 coord) //F1: Closest Feature Point
{
    // Scale input space (controls cell size)
    float3 scaledCoord = coord * settings.scale;

    // Grid cell and local position
    float3 baseCellFloat = floor(scaledCoord);
    int3 baseCell = int3(baseCellFloat);
    float3 localPos = scaledCoord - baseCellFloat;

    // Initialize with current cell
    int3 closestOffset = int3(0, 0, 0);

    //Calculate feature point by hashing the cell
    //If randomness is 0, the feature point is on the corner of the cell
    //If randomness is 1, the frature point is equal to the hashed value
    float3 featurePoint = HashInt3ToNormalizedFloat3_LCG(baseCell) * settings.randomness;
    
    //Assume the closest feature point is the base cell Feature point
    float closestDistance = ComputeVoronoiDistance(featurePoint, localPos, settings.distanceMetric);
    float3 closestFeaturePoint = featurePoint;

    // Search neighboring cells for closer feature points (3x3x3 iteration)
    [unroll]
    for (int z = -1; z <= 1; z++)
    {
        [unroll]
        for (int y = -1; y <= 1; y++)
        {
            [unroll]
            for (int x = -1; x <= 1; x++)
            {
                int3 offset = int3(x, y, z);
                int3 neighborCell = baseCell + offset;

                // Generate candidate feature point
                float3 candidateFeaturePointLocal = HashInt3ToNormalizedFloat3_LCG(neighborCell) * settings.randomness;
                float3 candidateFeaturePoint = float3(offset) + candidateFeaturePointLocal;

                //Calculate distance to feature point based on metric
                float distance = ComputeVoronoiDistance(candidateFeaturePoint, localPos, settings.distanceMetric);

                // Check if closer
                if (distance < closestDistance)
                {
                    closestDistance = distance;
                    closestOffset = offset;
                    closestFeaturePoint = candidateFeaturePoint;
                }
            }
        }
    }

    // Output result
    VoronoiResult result;
    result.featurePointDistance = closestDistance / settings.scale; //Distance to the closest feature point (with scale fix)
    result.cellColor = HashInt3ToNormalizedFloat3_LCG(baseCell + closestOffset); //Cell Color is actualy a unique float3 assigned to points that share the same closest feature point
    result.featurePointPosition = (baseCellFloat + closestFeaturePoint) / settings.scale; //This is the absolute feature point position (Same coord coordinates)

    return result;
}

VoronoiResult ComputeSmoothVoronoiF1(VoronoiSettings settings, float3 coord) //Blend between nearby feature points
{
    float3 scaledCoord = coord * settings.scale;

    float3 baseCellFloat = floor(scaledCoord);
    int3 baseCell = int3(baseCellFloat);
    float3 localPos = scaledCoord - baseCellFloat;

    // Accumulators
    float blendedDistance = 0.0;
    float3 blendedColor = float3(0.0, 0.0, 0.0);
    float3 blendedPosition = float3(0.0, 0.0, 0.0);

    bool isFirstSample = true;

    float safeSmoothness = max(settings.smoothness, 1e-5); //To be used inside loops
    
    // Search neighboring cells
    //[unroll] //Avoid Unrolling on Big Loops
    for (int z = -2; z <= 2; z++)
    {
        //[unroll]
        for (int y = -2; y <= 2; y++)
        {
            //[unroll]
            for (int x = -2; x <= 2; x++)
            {
                int3 cellOffset = int3(x, y, z);
                int3 neighborCell = baseCell + cellOffset;

                float3 hashedNeighborCell = HashInt3ToNormalizedFloat3_LCG(neighborCell);
                
                // Generate feature point inside the cell
                float3 randomOffset = hashedNeighborCell * settings.randomness;
                float3 featurePoint = float3(cellOffset) + randomOffset;

                // Compute distance to feature point
                float distanceToPoint = ComputeVoronoiDistance(featurePoint, localPos, settings.distanceMetric);

                // Compute blend weight
                float blendFactor;
                
                if (isFirstSample) //Initialize for first sample
                {
                    blendFactor = 1.0;
                    isFirstSample = false;
                }
                else
                {
                    float t = 0.5 + 0.5 * (blendedDistance - distanceToPoint) / safeSmoothness;
                    blendFactor = smoothstep(0.0, 1.0, t);
                }

                // Smooth minimum correction (case where two nearby feature points are similar distance to coord, and therefore blend factor is more or less 0.5)
                float correction = settings.smoothness * blendFactor * (1.0 - blendFactor);

                // Blend distance
                blendedDistance = lerp(blendedDistance, distanceToPoint, blendFactor) - correction;

                // Adjust correction for color and position (reduces the correction as smoothness increases, mainly because it is not necessary and will generate excessive distortion)
                // It is a small visual tweak
                float adjustedCorrection = correction / (1.0 + 3.0 * safeSmoothness);

                // Cell color
                float3 cellColor = hashedNeighborCell;

                // Blend color and position
                blendedColor = lerp(blendedColor, cellColor, blendFactor) - adjustedCorrection;
                blendedPosition = lerp(blendedPosition, featurePoint, blendFactor) - adjustedCorrection;
            }
        }
    }

    // Final result
    VoronoiResult result;
    result.featurePointDistance = blendedDistance / settings.scale;
    result.cellColor = blendedColor;
    result.featurePointPosition = (baseCellFloat + blendedPosition) / settings.scale;

    return result;
}

void GenerateVoronoiSimple_float(float3 RefferenceVector, float Randomness, float Scale, float DistanceMetric, out float3 FeaturePointPosition, out float FeaturePointDistance, out float3 CellColor)
{
    VoronoiSettings settings = (VoronoiSettings) 0; //Initialize Voronoi Settings
    settings.randomness = Randomness;
    settings.scale = Scale;
    settings.distanceMetric = DistanceMetric;

    VoronoiResult result = ComputeSimpleVoronoiF1(settings, RefferenceVector);

    FeaturePointPosition = normalize(result.featurePointPosition);
    FeaturePointDistance = result.featurePointDistance;
    CellColor = result.cellColor;
}

void GenerateVoronoiSmooth_float(float3 RefferenceVector, float Randomness, float Smoothness, int DistanceMetric, float Scale, out float3 FeaturePointPosition, out float FeaturePointDistance, out float3 CellColor)
{
    VoronoiSettings settings = (VoronoiSettings) 0;
    settings.randomness = Randomness;
    settings.smoothness = Smoothness;
    settings.distanceMetric = DistanceMetric;
    settings.scale = Scale;

    VoronoiResult result = ComputeSmoothVoronoiF1(settings, RefferenceVector);

    FeaturePointPosition = normalize(result.featurePointPosition);
    FeaturePointDistance = result.featurePointDistance;
    CellColor = result.cellColor;
}
#endif