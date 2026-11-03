#include <metal_stdlib>
using namespace metal;
struct RingFrame {
    float time; uint kind; float2 size; float2 center; float2 scale;
    float rotation; float progress; uint style; float padding; float4 monochrome;
};
struct FullVertex { float4 position [[position]]; float2 uv; };
vertex FullVertex ringFullVertex(uint id [[vertex_id]]) {
    float2 uv=id==0?float2(0,0):id==1?float2(2,0):float2(0,2);
    return {float4(uv.x*2.-1.,1.-uv.y*2.,0,1),uv};
}
float2 ringRotate(float2 p,float a){return float2(p.x*cos(a)-p.y*sin(a),p.x*sin(a)+p.y*cos(a));}
float2 ringRotateBasis(float2 p,float2 basis){return float2(p.x*basis.x-p.y*basis.y,p.x*basis.y+p.y*basis.x);}
float2 ringModel(float2 uv,constant RingFrame& a,float2 basis){return ringRotateBasis(uv*a.size-a.center,float2(basis.x,-basis.y))/a.scale/114.27;}
float ringGaussian(float2 p,float2 at,float2 sigma){float2 q=(p-at)/sigma;return exp(-dot(q,q));}
float3 ringEnvironment(float3 direction) {
    float u=atan2(direction.x,direction.z),v=asin(clamp(direction.y,-1.,1.));
    float warm=exp(-pow((u+2.50)/.16,2.)-pow((v+.45)/.16,2.));
    float blue=exp(-pow((u-2.48)/.15,2.)-pow((v+.62)/.18,2.));
    float lower=exp(-pow((u+2.40)/.26,2.)-pow((v-.38)/.18,2.));
    float narrow=exp(-pow((u-2.52)/.10,2.)-pow((v-.02)/.85,2.));
    return float3(.012,.026,.070)+float3(3.9,3.45,3.0)*warm+float3(1.1,3.5,8.3)*blue
        +float3(.2,1.1,3.2)*lower+float3(.8,2.3,6.2)*narrow;
}
float ringFresnel(float cosI,float eta) {
    float sinT2=(1.-cosI*cosI)/(eta*eta);
    float cosT=sqrt(max(0.,1.-sinT2));
    float rs=(cosI-eta*cosT)/(cosI+eta*cosT);
    float rp=(eta*cosI-cosT)/(eta*cosI+cosT);
    return .5*(rs*rs+rp*rp);
}
struct RingLight {float4 position;float4 color;};
struct RingLightField {float4 position;float4 radiance;float4 basis;float4 accent;};
fragment float4 ringGlass(FullVertex in [[stage_in]],constant RingFrame& a [[buffer(0)]],constant RingLight* lights [[buffer(1)]],constant RingLightField* fields [[buffer(2)]],constant uint& fieldCount [[buffer(3)]],constant float2& rotationBasis [[buffer(4)]],texture2d<float> emittedLight [[texture(0)]]) {
    float2 p=ringModel(in.uv,a,rotationBasis);float r=length(p);
    float aa=max(length(dfdx(p)),length(dfdy(p)))*1.4;
    float coverage=1.-smoothstep(1.-aa,1.+aa,r);
    if(coverage<=0.)return float4(0.);
    float z=sqrt(max(.0001,1.-dot(p,p))),eta=1.46;
    float angular=atan2(p.y,p.x);
    float ripple=.005*sin(angular*13.+.8*sin(angular*5.+a.time*.035));
    float3 n=normalize(float3(p*(1.+ripple),z));
    float3 reflected=reflect(float3(0,0,-1),n);
    float f=ringFresnel(z,eta);
    // Trace through the outer shell and the front inner air interface.
    float3 transmitted=refract(float3(0,0,-1),n,1./eta);
    float b=dot(n,transmitted),disc=b*b-(1.-.968*.968);
    float3 innerNormal=n;
    float2 refractedPosition=p;
    float thickness=.03/max(.13,z);
    if(disc>0.) {
        float travel=-b-sqrt(disc);
        innerNormal=normalize(n+transmitted*travel);
        float cosine=dot(transmitted,innerNormal);
        float critical=1.-eta*eta*(1.-cosine*cosine);
        float3 airRay=refract(transmitted,innerNormal,eta);
        if(dot(airRay,airRay)>.1&&airRay.z<-.15) {
            transmitted=airRay;
            float3 innerPosition=n+refract(float3(0,0,-1),n,1./eta)*travel;
            float distanceToPlane=-innerPosition.z/airRay.z;
            float2 hit=innerPosition.xy+airRay.xy*distanceToPlane;
            // Blend grazing rays continuously into the silhouette. A hard switch
            // at z=-.15 jumps both moving heads and their refracted trails.
            refractedPosition=mix(p,hit,smoothstep(.15,.30,-airRay.z)*smoothstep(0.,.04,critical));
        }
        thickness=travel;
    }
    float3 absorption=exp(-float3(.8,.35,.10)*thickness);
    constexpr sampler lightSampler(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 viewUV=(a.center+ringRotateBasis(refractedPosition*a.scale*114.27,rotationBasis))/a.size;
    float2 ghost=p*.955+reflected.xy*.008;
    float2 ghostUV=(a.center+ringRotateBasis(ghost*a.scale*114.27,rotationBasis))/a.size;
    float4 lightValue=emittedLight.sample(lightSampler,viewUV);
    float3 direct=lightValue.rgb*(1.-f)*absorption;
    // Alpha in the intermediate emission field stores optical depth, not opacity.
    // A narrow displaced absorption trough beside each caustic adds real light/dark
    // structure without introducing a separate raster texture or another mesh pass.
    float localTransmission=exp(-min(lightValue.a,1.5));
    // The inner reflection should reveal fine paths without duplicating the six
    // bright star cores. Compress its peaks before applying the grazing-angle gain.
    float3 bounced=emittedLight.sample(lightSampler,ghostUV).rgb;
    float bouncedPeak=max(bounced.r,max(bounced.g,bounced.b));
    float3 secondary=bounced/(1.+bouncedPeak/.75)
        *mix(.045,.16,smoothstep(.45,.96,r));
    float3 c=direct+secondary;
    // Directional environment reflections follow the sphere normal. The radial
    // illumination below supplies diffuse shoulders; this supplies a curved,
    // Fresnel-weighted specular highlight rather than another flat light patch.
    c+=ringEnvironment(reflected)*f*.30*localTransmission;
    // The transverse distance to a light is identical at all six depth samples.
    // Retain every sample, evaluate this shared part only once per light.
    float depthWeight=2.*z/6.;
    for(int light=0;light<6;light++) {
        float2 transverse=p-lights[light].position.xy;
        float transverse2=dot(transverse,transverse);
        for(int step=0;step<6;step++) {
            float deltaZ=z*(1.-2.*(float(step)+.5)/6.)-lights[light].position.z;
            float distance2=max(.04,transverse2+deltaZ*deltaZ);
            float attenuation=exp(-sqrt(distance2)*1.45)/(distance2+.06);
            c+=lights[light].color.rgb*attenuation*.016*depthWeight;
        }
    }
    // Positive radial light lobes describe uneven shell reflections. Signed RGB
    // residual corrections and a uniform rim are deliberately absent.
    float fieldTransmission=mix(.96,1.02,f)*localTransmission;
    for(uint i=0;i<min(fieldCount,80u);i++) {
        float2 center=fields[i].position.xy;
        float2 direction=fields[i].basis.xy;
        float2 offset=p-center;
        float2 surfaceOffset=float2(dot(offset,direction),dot(offset,float2(-direction.y,direction.x)));
        float2 delta=surfaceOffset*fields[i].position.zw;
        float broad=exp(-dot(delta,delta));
        if(fields[i].basis.z>.7 && fields[i].basis.z<.9) {
            // A few isolated curved specular slivers sit on the broad shoulder.
            // A repeated wave would produce regular contour bands around the ball.
            float crease=surfaceOffset.x+1.1*surfaceOffset.y*surfaceOffset.y
                -fields[i].accent.x;
            float footprint=max(fwidth(crease),a.padding*2.);
            float width=sqrt(.002*.002+footprint*footprint/12.);
            float ridge=exp(-crease*crease/(width*width))*.002/width;
            float gate=exp(-pow(surfaceOffset.y*fields[i].position.w/.38,4.))*fields[i].accent.y;
            broad+=ridge*gate*3.2;
        }
        float reflected=broad;
        if(fields[i].basis.z>.9) {
            // A separated narrow caustic carries the sharp reflection while the
            // original lobe supplies its soft shoulder. Radius varies by lobe;
            // this must not collapse into a uniform circular outline.
            float2 edgeOffset=p-fields[i].accent.zw;
            float2 q=float2(dot(edgeOffset,direction),dot(edgeOffset,float2(-direction.y,direction.x)));
            float width=sqrt(.0045*.0045+aa*aa/12.);
            float edge=exp(-q.x*q.x/(width*width)-q.y*q.y*fields[i].position.w*fields[i].position.w);
            reflected=broad*.60+edge*.70;
        }
        c+=fields[i].radiance.rgb*reflected*fieldTransmission;
    }
    return float4(max(c,float3(0.))*coverage,coverage);
}
struct RingMeshVertex { float2 position;float2 local;float distance;float strength;float4 color;float4 animation;float4 wave; };
struct RingVarying {
    float4 position [[position]];float2 model;float2 local;float distance;float strength;float4 color;float4 optics;
    uint streamIndex [[flat]];
};
vertex RingVarying ringMeshVertex(uint id [[vertex_id]],const device RingMeshVertex* vertices [[buffer(0)]],constant RingFrame& a [[buffer(1)]],constant float4& flow [[buffer(2)]],constant float4* streams [[buffer(3)]],constant float4* glints [[buffer(4)]]) {
    RingMeshVertex v=vertices[id];
    uint index=uint(v.animation.z);
    float4 optics=v.wave;
    if(v.animation.w==4.) {
        optics=streams[index];
    }else if(v.animation.w==2.) {
        v.position+=glints[index].xy;
        v.strength*=glints[index].z;
    }else if(v.animation.w==3.) {
        v.strength*=glints[index].w;
    }
    float2 pixel=a.center+ringRotateBasis(v.position*a.scale*114.27,flow.zw);
    RingVarying out;out.position=float4(pixel.x/a.size.x*2.-1.,1.-pixel.y/a.size.y*2.,0,1);
    out.model=v.position;out.local=v.local;out.distance=v.distance;out.strength=v.strength;out.color=v.color;out.optics=optics;out.streamIndex=index;return out;
}
fragment float4 ringEmission(RingVarying in [[stage_in]],constant RingFrame& a [[buffer(1)]],constant float4* companions [[buffer(2)]]) {
    // Emissions may sit just outside the projected silhouette after inverse placement;
    // the glass pass clips the final sphere, not this intermediate light field.
    float mask=1.-smoothstep(1.06,1.08,length(in.model));
    if(mask<=0.)discard_fragment();
    float3 c;float opticalDepth=0.;
    if(in.color.w<.5) {
        float rasterFootprint=length(float2(dfdx(in.distance),dfdy(in.distance)));
        float footprint=max(rasterFootprint,a.padding*2.);
        bool meteor=in.color.w>.125;
        if(meteor) {
            c=float3(0.);
            float4 secondary=companions[in.streamIndex];
            float headWidth=max(length(float2(dfdx(in.local.y),dfdy(in.local.y)))
                *footprint/max(rasterFootprint,.00001),.00001);
            // Evaluate the wrapped age per fragment. Interpolating already-wrapped
            // ages at the moving head would create a visible mesh-segment step.
            for(int comet=0;comet<3;comet++) {
                float head=comet==0?in.optics.x:comet==1?secondary.x:secondary.y;
                float gain=comet==0?1.:comet==1?secondary.z:secondary.w;
                float extent=in.optics.z*(comet==0?1.:comet==1?.72:.52);
                float age=fract((head-in.local.y)*in.optics.y/6.283185307+1.)*6.283185307/extent;
                if(age>=1.)continue;
                // Filter the head boundary over one final display pixel. A fixed
                // fraction of tail length left a visible gap behind small round heads.
                float envelope=smoothstep(0.,headWidth,age*extent)*pow(max(0.,1.-age),1.25)*gain;
                float sigma=in.optics.w*(comet==0?1.:.78)*pow(max(.001,1.-age),.65);
                float filtered=sqrt(sigma*sigma+footprint*footprint/12.);
                float core=exp(-pow(in.distance/filtered,2.))*sigma/filtered;
                float soft=exp(-pow(in.distance/.007,2.));
                c+=in.color.rgb*(core+soft*.035)*in.strength*envelope;
                float width=sqrt(.0045*.0045+footprint*footprint/12.);
                float trough=exp(-pow((in.distance-.006)/width,2.))*.0045/width;
                opticalDepth+=trough*.08*in.strength*envelope;
            }
        }else{
        float sigma=in.local.x;
        // A pixel box has variance width²/12. The previous doubled derivative and
        // .30 multiplier blurred a narrow caustic into a stripe over a pixel wide.
        float filtered=sqrt(sigma*sigma+footprint*footprint/12.);
        float core=exp(-pow(in.distance/filtered,2.))*sigma/filtered;
        float soft=exp(-pow(in.distance/.007,2.));
        c=in.color.rgb*(core+soft*.035)*in.strength;
        if(abs(in.local.y)>.001) {
            float width=sqrt(.0045*.0045+footprint*footprint/12.);
            float trough=exp(-pow((in.distance-in.local.y)/width,2.))*.0045/width;
            float brightness=max(in.color.r,max(in.color.g,in.color.b));
            opticalDepth=trough*.18*smoothstep(.02,.45,brightness)*in.strength;
        }
        }
    }else{
        float2 d=in.local;
        float footprint=max(max(length(dfdx(d)),length(dfdy(d))),a.padding*2.);
        bool dust=in.color.w>1.5;
        float sigma=dust?in.distance:in.optics.x;
        float filtered=sqrt(sigma*sigma+footprint*footprint/12.);
        float core=exp(-dot(d,d)/(filtered*filtered))*sigma*sigma/(filtered*filtered);
        // Keep the star's light concentrated in a small core and tapered rays.
        // A broad, bright Gaussian reads as a flat glowing disc at desktop scale.
        float haloWidth=dust?.014:in.optics.y;
        float halo=exp(-dot(d,d)/(haloWidth*haloWidth));
        if(dust) {
            c=in.color.rgb*(core+halo*.006)*in.strength;
        }else{
        float w=max(.0015,footprint*.26);
        float flare=exp(-abs(d.x)/w)*exp(-abs(d.y)/.065)+exp(-abs(d.y)/w)*exp(-abs(d.x)/.065);
        float2 diagonal=ringRotate(d,.785398);
        flare+=(exp(-abs(diagonal.x)/(w*.8))*exp(-abs(diagonal.y)/.045)
            +exp(-abs(diagonal.y)/(w*.8))*exp(-abs(diagonal.x)/.045))*.12;
        float3 coreTint=in.color.r>in.color.b*1.1?float3(1.,.80,.24):mix(float3(.10,.50,1.),float3(1.),in.optics.w);
        float3 rayTint=in.color.r>in.color.b*1.1?in.color.rgb:mix(in.color.rgb,coreTint,.12*in.optics.w);
        c=(coreTint*core*23.+in.color.rgb*halo*in.optics.z+rayTint*flare*in.distance)*in.strength;
        }
    }
    return float4(c*mask,opticalDepth*mask);
}
kernel void ringDownsample(texture2d<float,access::read> source [[texture(0)]],texture2d<float,access::write> target [[texture(1)]],constant float& threshold [[buffer(0)]],uint2 id [[thread_position_in_grid]]) {
    if(id.x>=target.get_width()||id.y>=target.get_height())return;
    uint2 size=uint2(source.get_width(),source.get_height());uint2 p=id*2;
    float3 c=(source.read(min(p,size-1)).rgb+source.read(min(p+uint2(1,0),size-1)).rgb+source.read(min(p+uint2(0,1),size-1)).rgb+source.read(min(p+1,size-1)).rgb)*.25;
    if(threshold>=0.){float brightness=max(c.r,max(c.g,c.b));c*=smoothstep(threshold*.5,threshold*1.5,brightness);}
    target.write(float4(c,0.),id);
}
kernel void ringBlur(texture2d<float,access::read> source [[texture(0)]],texture2d<float,access::write> target [[texture(1)]],constant int2& axis [[buffer(0)]],uint2 id [[thread_position_in_grid]]) {
    if(id.x>=target.get_width()||id.y>=target.get_height())return;
    int2 size=int2(source.get_width(),source.get_height()),p=int2(id);
    float3 c=source.read(id).rgb*.227027;
    const float weights[4]={.194595,.121622,.054054,.016216};
    for(int i=1;i<=4;i++){c+=(source.read(uint2(clamp(p+axis*i,int2(0),size-1))).rgb+source.read(uint2(clamp(p-axis*i,int2(0),size-1))).rgb)*weights[i-1];}
    target.write(float4(c,0),id);
}
float3 ringTone(float3 c){
    c=max(c,float3(0.));
    c=clamp((c*(2.51*c+.03))/(c*(2.43*c+.59)+.14),0.,1.);
    return select(c*12.92,1.055*pow(c,float3(1./2.4))-.055,c>.0031308);
}

fragment float4 ringComposite(FullVertex in [[stage_in]],constant RingFrame& a [[buffer(0)]],constant float2& rotationBasis [[buffer(1)]],constant uint& bloomCount [[buffer(2)]],texture2d<float> scene [[texture(0)]],texture2d<float> bloom0 [[texture(1)]],texture2d<float> bloom1 [[texture(2)]],texture2d<float> bloom2 [[texture(3)]],texture2d<float> bloom3 [[texture(4)]],texture2d<float> bloom4 [[texture(5)]]) {
    constexpr sampler linearSampler(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 p=ringModel(in.uv,a,rotationBasis);float r=length(p),amount=a.progress;
    float4 hdr=scene.sample(linearSampler,in.uv);
    float3 scatter=bloom0.sample(linearSampler,in.uv).rgb*.65+bloom1.sample(linearSampler,in.uv).rgb*.36+bloom2.sample(linearSampler,in.uv).rgb*.16;
    if(bloomCount>3)scatter+=bloom3.sample(linearSampler,in.uv).rgb*.08;
    if(bloomCount>4)scatter+=bloom4.sample(linearSampler,in.uv).rgb*.04;
    // Keep the halo around the sphere; no separate ground-plane light pools.
    float halo=exp(-pow((r-1.)/.09,2.))*.007;
    float coverage=hdr.a;
    float3 glow=ringTone((scatter+float3(.06,.28,.70)*halo)*.90);
    // Tone-map unassociated body radiance, then premultiply exactly once. Applying
    // the nonlinear tone curve to already premultiplied HDR created edge color/alpha
    // mismatches, especially against a bright desktop.
    float3 body=ringTone((hdr.rgb/max(coverage,.00001)+scatter)*.90);
    if(a.style==3u)body=mix(a.monochrome.rgb,body,amount);
    float3 color=body*coverage+glow*(1.-coverage);
    float alpha=coverage+max(glow.r,max(glow.g,glow.b))*(1.-coverage);
    if(a.style==0u&&r>165./114.27*amount&&amount<1.)discard_fragment();
    if(a.style==1u&&length(p+1.)>325./114.27*amount&&amount<1.)discard_fragment();
    if(a.style==2u&&amount<1.) {
        float angle=atan2(p.y,p.x);if(angle<0.)angle+=6.2831853;
        float part=floor(angle/(3.14159265/16.));float av=part*3.14159265/16.,bv=av+3.14159265/16.;
        float ra=fmod(part,2.)<.5?185.:135.,rb=320.-ra;
        float2 v0=float2(cos(av),sin(av))*ra,v1=float2(cos(bv),sin(bv))*rb,ray=float2(cos(angle),sin(angle)),d=v1-v0;
        float radius=abs((v0.x*v1.y-v0.y*v1.x)/(ray.x*d.y-ray.y*d.x))/114.27;
        if(r>radius*amount)discard_fragment();
    }
    // Stationary sub-byte dithering prevents concentric bands in the dark glass gradient.
    float dither=(fract(sin(dot(floor(in.position.xy),float2(12.9898,78.233)))*43758.5453)-.5)/255.;
    if(alpha>.002)color=clamp(color+dither*alpha,float3(0.),float3(alpha));
    if(r>1.){color*=amount;alpha*=amount;}
    return float4(color,alpha);
}
