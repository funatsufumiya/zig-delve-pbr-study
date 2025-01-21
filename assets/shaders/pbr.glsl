//------------------------------------------------------------------------------
// PBR対応した基本ライティングシェーダー
//------------------------------------------------------------------------------
#pragma sokol @header const m = @import("../../math.zig")
#pragma sokol @ctype mat4 m.Mat4

#pragma sokol @vs vs
uniform vs_params {
    mat4 u_projViewMatrix;
    mat4 u_modelMatrix;
    mat4 u_normalMatrix;    // 法線変換用
    vec4 u_cameraPos;
    vec4 u_color;
    vec4 u_tex_pan;
};

in vec4 pos;
in vec4 color0;
in vec2 texcoord0;
in vec3 normals;
in vec4 tangents;

out vec4 color;
out vec2 uv;
out vec3 normal;
out vec4 tangent;
out vec3 v_Position;    // ワールド座標
out vec3 v_Normal;      // ワールド法線
out vec3 v_ViewDir;     // 視線方向

void main() {
    color = color0 * u_color;
    uv = texcoord0 + u_tex_pan.xy;
    
    // PBR計算に必要な出力値を計算
    v_Position = (u_modelMatrix * pos).xyz;
    v_Normal = normalize(mat3(u_normalMatrix) * normals);
    v_ViewDir = normalize(u_cameraPos.xyz - v_Position);
    
    normal = v_Normal;
    tangent = tangents;
    
    gl_Position = u_projViewMatrix * vec4(v_Position, 1.0);
}
#pragma sokol @end

#pragma sokol @fs fs
uniform texture2D tex;
uniform texture2D tex_metallic_roughness;  // メタリック(B)とラフネス(G)のテクスチャ
uniform texture2D tex_normal;              // 法線マップ
uniform texture2D tex_ao;                  // アンビエントオクルージョン
uniform sampler smp;

// IBL用テクスチャ
uniform textureCube tex_irradiance;        // 拡散IBL
uniform textureCube tex_prefilter;         // 鏡面IBL
uniform texture2D tex_brdf_lut;            // BRDF LUT

uniform fs_params {
    vec4 u_cameraPos;
    vec4 u_color_override;
    float u_alpha_cutoff;
    
    // PBRマテリアルパラメータ
    vec4 u_BaseColorFactor;
    float u_MetallicFactor;
    float u_RoughnessFactor;
    float u_AOStrength;
    
    // ライティングパラメータ
    vec4 u_ambient_light;
    vec4 u_dir_light_dir;
    vec4 u_dir_light_color;
    float u_num_point_lights;
    vec4 u_point_light_data[32];
    
    // フォグパラメータ
    vec4 u_fog_data;
    vec4 u_fog_color;
};

in vec4 color;
in vec2 uv;
in vec3 normal;
in vec4 tangent;
in vec3 v_Position;
in vec3 v_Normal;
in vec3 v_ViewDir;

out vec4 frag_color;

// PBR関連の定数
const float PI = 3.14159265359;
const vec3 dielectricSpecular = vec3(0.04);

// 分布関数 (GGX/Trowbridge-Reitz)
float D_GGX(float NoH, float roughness) {
    float alpha = roughness * roughness;
    float alpha2 = alpha * alpha;
    float NoH2 = NoH * NoH;
    float denom = NoH2 * (alpha2 - 1.0) + 1.0;
    return alpha2 / (PI * denom * denom);
}

// 幾何減衰関数 (Smith GGX)
float G_Smith(float NoV, float NoL, float roughness) {
    float alpha = roughness * roughness;
    float k = alpha / 2.0;
    float ggx1 = NoV / (NoV * (1.0 - k) + k);
    float ggx2 = NoL / (NoL * (1.0 - k) + k);
    return ggx1 * ggx2;
}

// フレネル関数 (Schlick)
vec3 F_Schlick(vec3 f0, float VoH) {
    return f0 + (1.0 - f0) * pow(1.0 - VoH, 5.0);
}

// IBL関連の計算
vec3 getIBLContribution(vec3 n, vec3 v, vec3 baseColor, float metallic, float roughness) {
    vec3 f0 = mix(dielectricSpecular, baseColor, metallic);
    vec3 r = reflect(-v, n);
    
    vec3 irradiance = texture(samplerCube(tex_irradiance, smp), n).rgb;
    vec3 diffuse = irradiance * baseColor * (1.0 - metallic);
    
    const float MAX_REFLECTION_LOD = 4.0;
    float lod = roughness * MAX_REFLECTION_LOD;
    vec3 prefilteredColor = textureLod(samplerCube(tex_prefilter, smp), r, lod).rgb;
    vec2 brdf = texture(sampler2D(tex_brdf_lut, smp), vec2(max(dot(n, v), 0.0), roughness)).rg;
    vec3 specular = prefilteredColor * (f0 * brdf.x + brdf.y);
    
    return diffuse + specular;
}

// フォグ計算関数の定義
float calcFogFactor(float distance_to_eye) {
    float fog_start = u_fog_data.x;
    float fog_end = u_fog_data.y;
    float fog_amount = u_fog_color.a;
    float fog_factor = (distance_to_eye - fog_start) / (fog_end - fog_start);
    return clamp(fog_factor * fog_amount, 0.0, 1.0);
}

void main() {
    // ベースカラーとPBRパラメータの取得
    vec4 baseColorTex = texture(sampler2D(tex, smp), uv);
    vec4 metallicRoughness = texture(sampler2D(tex_metallic_roughness, smp), uv);
    float metallic = metallicRoughness.b * u_MetallicFactor;
    float roughness = metallicRoughness.g * u_RoughnessFactor;
    vec3 baseColor = baseColorTex.rgb * u_BaseColorFactor.rgb;
    
    // 法線マッピング
    vec3 N = normalize(normal);
    vec3 V = normalize(u_cameraPos.xyz - v_Position);
    
    // F0の計算 (金属度に基づく)
    vec3 F0 = mix(dielectricSpecular, baseColor, metallic);
    
    // 直接光の計算
    vec3 Lo = vec3(0.0);
    
    // ポイントライト
    for(int i = 0; i < int(u_num_point_lights); ++i) {
        vec4 lightPos = u_point_light_data[i * 2];
        vec4 lightColor = u_point_light_data[i * 2 + 1];
        
        vec3 L = normalize(lightPos.xyz - v_Position);
        vec3 H = normalize(V + L);
        
        float distance = length(lightPos.xyz - v_Position);
        float attenuation = 1.0 / (distance * distance);
        vec3 radiance = lightColor.rgb * attenuation;
        
        float NoV = max(dot(N, V), 0.0);
        float NoL = max(dot(N, L), 0.0);
        float NoH = max(dot(N, H), 0.0);
        float VoH = max(dot(V, H), 0.0);
        
        // Cook-Torrance BRDF
        float D = D_GGX(NoH, roughness);
        float G = G_Smith(NoV, NoL, roughness);
        vec3 F = F_Schlick(F0, VoH);
        
        vec3 specular = (D * G * F) / max(4.0 * NoV * NoL, 0.001);
        vec3 kD = (vec3(1.0) - F) * (1.0 - metallic);
        
        Lo += (kD * baseColor / PI + specular) * radiance * NoL;
    }
    
    // ディレクショナルライト
    {
        vec3 L = normalize(-u_dir_light_dir.xyz);
        vec3 H = normalize(V + L);
        vec3 radiance = u_dir_light_color.rgb;
        
        float NoV = max(dot(N, V), 0.0);
        float NoL = max(dot(N, L), 0.0);
        float NoH = max(dot(N, H), 0.0);
        float VoH = max(dot(V, H), 0.0);
        
        float D = D_GGX(NoH, roughness);
        float G = G_Smith(NoV, NoL, roughness);
        vec3 F = F_Schlick(F0, VoH);
        
        vec3 specular = (D * G * F) / max(4.0 * NoV * NoL, 0.001);
        vec3 kD = (vec3(1.0) - F) * (1.0 - metallic);
        
        Lo += (kD * baseColor / PI + specular) * radiance * NoL;
    }
    
    // IBL (環境光)の追加
    vec3 ambient = getIBLContribution(N, V, baseColor, metallic, roughness);
    
    // AOの適用
    float ao = texture(sampler2D(tex_ao, smp), uv).r;
    ambient *= mix(1.0, ao, u_AOStrength);
    
    // 最終カラーの合成
    vec3 color = ambient + Lo;
    
    // トーンマッピングとガンマ補正
    color = color / (color + vec3(1.0));
    color = pow(color, vec3(1.0/2.2));
    
    // フォグの適用
    float fogFactor = calcFogFactor(length(u_cameraPos.xyz - v_Position));
    color = mix(color, u_fog_color.rgb, fogFactor);
    
    frag_color = vec4(color, baseColorTex.a);
}

#pragma sokol @end

#pragma sokol @program pbr vs fs
