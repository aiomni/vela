#include <metal_stdlib>
using namespace metal;
struct Parameters { float time; uint kind; uint size; float footprint; };
constant float PI = 3.14159265359;
float hash(float2 p) { return fract(sin(dot(p, float2(127.1,311.7))) * 43758.5453); }
float noise(float2 p) {
    float2 i=floor(p), f=fract(p); f=f*f*(3.-2.*f);
    return mix(mix(hash(i),hash(i+float2(1,0)),f.x),mix(hash(i+float2(0,1)),hash(i+1.),f.x),f.y);
}
float fbm(float2 p) {
    float n=0.,a=.52; for(int i=0;i<5;i++){n+=a*noise(p);p=float2(p.x*1.62-p.y*1.17,p.x*1.17+p.y*1.62)+2.7;a*=.48;}return n;
}
float3 hsv(float h,float s,float v) {float3 p=abs(fract(h+float3(0,2./3.,1./3.))*6.-3.);return v*mix(float3(1),clamp(p-1.,0.,1.),s);}
float line(float2 p,float2 a,float2 b){float2 d=b-a;return length(p-a-d*clamp(dot(p-a,d)/dot(d,d),0.,1.));}
float3 stars(float2 uv,float t,float px=1./256.) {
    float3 c=0.;for(int layer=0;layer<3;layer++){
        float grid=layer==0?22.:layer==1?49.:90.; float2 q=uv*grid;float2 cell=floor(q);
        float seed=hash(cell+float(layer)*37.);float2 at=float2(hash(cell+17.2),hash(cell+53.1))*.7+.15;
        float2 d=(fract(q)-at)/grid; float size=layer==0?.0018:.0008;
        float sigma=sqrt(size*size+px*px*.16);
        float detail=1.-smoothstep(.30,.90,px*grid);
        float glow=exp(-dot(d,d)/(sigma*sigma))*(size*size/(sigma*sigma))*(.65+.35*sin(t*(.32+seed*.3)+seed*48.));
        float flare=seed>.93?exp(-abs(d.x)*2100.)*exp(-abs(d.y)*190.)+exp(-abs(d.y)*2100.)*exp(-abs(d.x)*190.):0.;
        c+=float3(.62+.38*seed,.75+.25*seed,1.)*(glow+flare*.13*min(1.,size/max(px,.0001)))*step(layer==0?.82:.89,seed)*detail;
    }return c;
}
float halo(float2 p,float2 center,float radius){return exp(-dot(p-center,p-center)/(radius*radius));}
float2 rotate2(float2 p,float angle){float c=cos(angle),s=sin(angle);return float2(p.x*c-p.y*s,p.x*s+p.y*c);}
// Two depth-separated emitting curtains. Their folded lower hems and fine
// fibers advect with the same coordinates, instead of sliding over a flat stripe.
float3 aurora(float2 uv,float t,bool cyan,float px) {
    float2 p=(uv-.5)*2.;float extent=sqrt(max(.001,1.-dot(p,p)));
    float3 c=float3(.002,.007,.027);float transmission=1.;
    float drift=t*.28;
    float fiberDetail=1.-smoothstep(.25,.85,px*45.);
    for(int sample=0;sample<18;sample++) {
        float z=extent*(1.-2.*(float(sample)+.5)/18.);
        float stepSize=2.*extent/18.;
        if(cyan) {
            // A broad translucent cyan veil bends diagonally through the volume;
            // this is a different silhouette from the hanging green curtain.
            float2 q=rotate2(p,-.30+.045*sin(t*.23));
            float x=q.x+z*.21;
            float crest=.40*sin(x*2.65-.45+drift*.62)+.12*sin(x*5.1-drift*.47);
            float d=q.y-crest-z*.30;
            float width=.14+.045*(.5+.5*sin(x*4.-drift));
            float fold=.026*sin(x*12.5+z*5.2-drift*.53)+.015*sin(x*24.+z*7.+drift*.38);
            d+=fold;
            float broad=exp(-pow(d/width,2.));
            float ribs=.25+.75*noise(float2(x*19.+z*11.,d*26.-drift*.70));
            float band=broad*ribs;
            float depth=.42*sin(x*2.2+drift*.37)+.17*cos(q.y*3.5-drift*.29);
            float sheet=exp(-pow((z-depth)/.22,2.));
            float filaments=.14+.86*noise(float2(x*11.+z*6.,d*17.-drift));
            float density=band*sheet*filaments;
            float edge=exp(-pow((d+width*.52)/max(.025,px*1.6),2.))*(.55+.45*noise(float2(x*16.+z*8.,drift*.45)));
            float3 tone=mix(float3(.012,.21,.83),float3(.045,.96,.73),smoothstep(-.45,.60,x+z*.35));
            c+=transmission*(tone*density*6.2+float3(.18,.94,1.1)*sheet*edge*1.45)*stepSize;
            float threadPhase=(d+.024*sin(x*11.+drift*.6)+.018*sin(x*24.-drift*.7))*90.;
            float filamentLight=mix(.196,pow(.5+.5*cos(threadPhase),8.),1.-smoothstep(.40,1.2,px*90.));
            c+=float3(.075,.72,1.1)*sheet*broad*filamentLight*(.25+.75*ribs)*stepSize*1.8;
            float back=exp(-pow((z+.48-.16*sin(x*3.7+drift*.34))/.19,2.));
            float backDistance=q.y+.30*sin(x*3.0+drift*.5)+.32-z*.25;
            c+=float3(.025,.34,.80)*back*exp(-pow(backDistance/.10,2.))*stepSize*1.4;
            transmission*=exp(-density*stepSize*.8);
        } else {
            float x=p.x+z*.20+.04*sin(z*3.+drift*.39);
            float depth=.34*sin(x*3.6+drift*.42)+.20*sin(x*8.5-drift*.31)+.08*sin(x*13.3+drift*.24);
            float sheet=exp(-pow((z-depth)/.105,2.));
            float hem=.24+.18*sin(x*2.9+.4-drift*.40)+.15*sin(x*5.3+drift*.28)+.13*sin(x*9.2+.8-drift*.35)+.25*z;
            float d=p.y-hem;
            float fiberX=x+.025*sin(d*5.+drift*.8);
            float fibers=mix(.48,.08+.92*noise(float2(fiberX*58.+z*3.,drift*.75)),fiberDetail);
            float veil=exp(min(d,0.)/.63)*(1.-smoothstep(-.018,.055,d));
            veil*=.40+.60*smoothstep(-.85,-.08,d);
            float lipWidth=max(.034,px*1.5);
            float lip=exp(-pow(d/lipWidth,2.))*.034/lipWidth;
            float hue=smoothstep(.03,.83,x-z*.19);
            float3 tone=mix(float3(.035,.98,.47),float3(.68,.075,1.05),hue);
            float3 hemTone=mix(float3(.44,1.25,.39),float3(.65,.36,1.22),hue);
            float density=sheet*veil*fibers;
            c+=transmission*(tone*density*6.5+hemTone*sheet*lip*4.0)*stepSize;
            transmission*=exp(-density*stepSize*1.1);
            float backDepth=-.51+.17*sin(x*4.2-drift*.25);
            float back=exp(-pow((z-backDepth)/.12,2.));
            float backHem=.20*sin(x*4.2+1.6+drift*.27)+.20*z;
            float bd=p.y-backHem;
            float backVeil=exp(min(bd,0.)/.80)*(1.-smoothstep(-.01,.055,bd));
            c+=mix(float3(.015,.40,.65),float3(.45,.06,.8),hue)*back*backVeil*stepSize*2.8;
        }
    }
    return c+stars(uv,t,px)*.65;
}
float4 volumeField(texture3d<float> field,float3 p,float footprint) {
    constexpr sampler volumeSampler(coord::normalized,address::repeat,filter::linear,mip_filter::linear);
    float lod=max(0.,log2(max(1.,footprint)));
    float3 f=fract(p),smooth=f*f*(3.-2.*f);
    float3 coordinates=mix(floor(p)+smooth,p,smoothstep(.0,1.,lod));
    return field.sample(volumeSampler,(coordinates+.5)/64.,level(lod));
}
float cloudField(texture3d<float> field,float3 p,float footprint) {
    return .58*volumeField(field,p,footprint).r+
        .28*volumeField(field,p*2.03+7.,footprint*2.03).r+
        .14*volumeField(field,p*4.07+13.,footprint*4.07).r;
}
float3 nebula(float2 uv,float t,bool fantasy,float px,texture3d<float> field) {
    float2 p=(uv-.5)*2.;float extent=sqrt(max(.001,1.-dot(p,p)));
    float3 c=float3(.0007,.002,.012);float transmission=1.;
    float2 view=rotate2(p,-.34);
    float footprint=px*4.8;
    float azimuth=atan2(p.y,p.x);
    float envelope=.16+.84*smoothstep(.25,.78,length(p)+.12*sin(azimuth*2.+.4));
    for(int j=0;j<16;j++) {
        float z=extent*(1.-2.*(float(j)+.5)/16.),stepSize=2.*extent/16.;
        float3 drift=fantasy?float3(-t*.082,t*.010,t*.025):float3(t*.070,-t*.042,t*.049);
        float3 q=float3(view,z)*2.4+drift;
        float3 warp=(volumeField(field,q*.67+11.,footprint*.67).gba-.5)*1.5;
        float n=cloudField(field,q+warp,footprint);
        float fine=volumeField(field,q*7.4+warp*2.+23.,footprint*7.4).g;
        float density=smoothstep(fantasy?.39:.51,fantasy?.65:.69,n)*envelope;
        float ridge=exp(-pow((n-(fantasy?.515:.58))/max(fantasy?.030:.021,px*.75),2.))*(.30+.70*fine)*envelope;
        if(!fantasy) {
            density*=.35+.95*smoothstep(.28,.72,fine);
            ridge=smoothstep(.555,.67,n)*pow(smoothstep(.28,.73,fine),2.)*2.2*envelope;
        }
        float chroma=volumeField(field,q*.82+31.,footprint*.82).b;
        float3 tint=mix(float3(.008,.032,.68),float3(.02,.82,1.3),smoothstep(.48,.77,chroma));
        tint=mix(tint,float3(.20,.025,.60),smoothstep(.74,.91,chroma));
        if(fantasy) tint=mix(float3(.03,.035,.23),float3(.25,.025,.38),smoothstep(.23,.78,chroma));
        float emission=fantasy?.50:2.6;
        c+=transmission*tint*(density*.70+ridge*1.5)*stepSize*emission;
        transmission*=exp(-density*stepSize*1.65);
    }
    if(fantasy) {
        float rimCloud=exp(-pow((length(p)-.84)/.17,2.));
        float warm=pow(max(0.,sin(azimuth*2.-.2+t*.055)),8.);
        c+=float3(.27,.022,.17)*rimCloud*warm*.55;
    }
    float2 starDrift=fantasy?float2(-t*.016,0.):float2(t*.002,-t*.0011);
    c+=stars(uv+starDrift,t,px)*(.75+transmission*.25);
    return c;
}
float3 rainbowBall(float2 uv,float t,float px,texture3d<float> field) {
    float2 p=(uv-.5)*2.;float r=length(p),z=sqrt(max(.001,1.-dot(p,p)));
    float2 q=rotate2(p,t*.12);
    float3 c=float3(.14,.032,.003);float transmission=1.;
    for(int j=0;j<10;j++) {
        float depth=z*(1.-2.*(float(j)+.5)/10.),stepSize=2.*z/10.;
        float3 at=float3(q,depth)*2.2+float3(t*.064,-t*.044,t*.033);
        float3 warp=(volumeField(field,at*.68+8.,px*3.).gba-.5)*1.3;
        float cloud=cloudField(field,at+warp,px*4.4);
        float density=smoothstep(.43,.68,cloud);
        float core=exp(-dot(p-float2(-.10,-.09),p-float2(-.10,-.09))/.62);
        float hot=smoothstep(.58,.75,cloud)*core;
        float fine=volumeField(field,at*5.0+23.,px*22.).g;
        float filament=exp(-pow((cloud-.57)/max(.019,px*.8),2.))*(.20+.80*fine)*core;
        c+=transmission*(float3(1.1,.15,.005)*density+float3(1.0,.42,.025)*hot+float3(.85,.35,.065)*filament*.35)*stepSize*1.7;
        transmission*=exp(-density*stepSize*.65);
    }
    float film=volumeField(field,float3(q*.85,z*.7)+float3(t*.025,7.,11.),px*2.).b;
    float angle=atan2(q.y,q.x);
    float3 iridescent=.50+.50*cos(angle+film*1.35+float3(.0,2.1,4.2));
    float coat=smoothstep(.62,.99,r+.09*(film-.5));
    c=mix(c,iridescent*1.35+float3(.10,.09,.11),coat*.52);
    c+=iridescent*pow(1.-z,2.)*.60;
    c+=float3(.8,.63,.24)*stars(uv,t,px)*.20;
    return c;
}
// Precomputed shuffled six-scene programs. Even starts and odd endings keep
// adjacent programs from repeating a scene; every program contains all six.
constant ushort neonSceneOrders[144] = {
    4,1,0,5,2,3,
    0,2,4,5,1,3,
    0,1,5,4,2,3,
    2,3,5,4,0,1,
    0,4,3,2,5,1,
    0,2,4,1,3,5,
    4,2,3,0,5,1,
    4,1,2,3,0,5,
    2,0,4,3,5,1,
    2,5,4,0,1,3,
    4,5,2,0,3,1,
    2,0,5,4,1,3,
    4,5,1,2,0,3,
    0,4,2,3,5,1,
    0,2,5,1,4,3,
    0,4,5,1,2,3,
    4,3,2,1,0,5,
    0,2,3,1,4,5,
    0,2,5,4,1,3,
    0,3,2,4,1,5,
    0,4,2,5,1,3,
    0,4,2,1,3,5,
    4,5,2,1,0,3,
    4,2,0,5,1,3
};
uint neonSceneAt(uint slot) {
    uint program=uint(hash(float2(float(slot/6),719.3))*24.)%24;
    return uint(neonSceneOrders[program*6+slot%6]);
}
float3 neonCity(float2 uv,float elapsed,float px) {
    // Slow the entire light show together so scene changes, beats, and motion
    // keep their original phase relationship at one quarter of the old speed.
    float t=elapsed*.25;
    float2 p=(uv-.5)*2.;float z=sqrt(max(.001,1.-dot(p,p)));
    float longitude=atan2(p.x,z)+t*.075;
    float latitude=asin(clamp(p.y,-1.,1.))+t*.028;
    float2 grid=float2(longitude*9.,latitude*12.5);
    float2 footprint=px*float2(18./max(z,.12),25./max(sqrt(max(.01,1.-p.y*p.y)),.15));
    float2 aa=clamp(footprint*1.35,float2(.025),float2(.5));
    float detail=1.-smoothstep(.4,1.15,max(footprint.x,footprint.y));
    float2 cell=floor(grid),f=fract(grid);
    float seed=hash(cell);
    // A full field of lights, with soft clusters and a small quieter eye area.
    // Avoid the former empty central stripe and synchronized whole columns.
    float rhythm=.72+.28*sin(t*.72+cell.x*.49-cell.y*.37);
    float clusters=.5+.5*sin(longitude*2.4+latitude*2.1+.55*sin(latitude*3.));
    float eyeSpace=exp(-pow(p.x/.38,2.)-pow((p.y+.01)/.30,2.));
    float band=(.72+.28*clusters)*(1.-.30*eyeSpace);
    float enabled=step(.25+.12*(1.-clusters),seed)*rhythm;
    float2 halfWindow=float2(.25+.06*hash(cell+13.),.23+.10*hash(cell+51.));
    float2 coverage=clamp((halfWindow-abs(f-.5))/aa+.5,0.,1.);
    float2 border=smoothstep(float2(0.),aa*.5,f)*smoothstep(float2(0.),aa*.5,1.-f);
    float tileFade=border.x*border.y;
    float window=coverage.x*coverage.y*tileFade;
    // Six shuffled light-show scenes, four beats each, with a crossfade.
    // All scenes illuminate the same accepted tile layout.
    float beatClock=t*(128./60.);
    float sceneClock=beatClock*.25;
    uint sceneSlot=uint(floor(sceneClock));
    uint scene=neonSceneAt(sceneSlot),nextScene=neonSceneAt(sceneSlot+1);
    float sceneBlend=smoothstep(.72,1.,fract(sceneClock));
    float weights[6]={0.,0.,0.,0.,0.,0.};
    weights[scene]=1.-sceneBlend;
    weights[nextScene]+=sceneBlend;
    float4 firstWeights=float4(weights[0],weights[1],weights[2],weights[3]);
    float2 extraWeights=float2(weights[4],weights[5]);
    float radius=length(p-float2(.08,-.10));
    float angle=atan2(p.y,p.x);
    float columnLevel=.33+.45*(.5+.5*sin(cell.x*.67+t*3.4));
    float bar=1.-smoothstep(columnLevel-.10,columnLevel+.10,.5+latitude/PI);
    float ripple=.5+.5*cos(radius*9.-beatClock*PI*.5);
    float checker=.5+.5*cos((floor(cell.x/3.)+floor(cell.y/4.))*PI-beatClock*PI);
    float sector=.5+.5*cos(angle*4.-beatClock*PI*.5);
    sector=mix(.5,sector,smoothstep(.08,.24,length(p)));
    float twin=.5+.5*cos(abs(longitude)*6.-beatClock*PI);
    float spiral=.5+.5*cos(angle*2.+radius*8.-beatClock*PI*.5);
    spiral=mix(.5,spiral,smoothstep(.08,.24,length(p)));
    float4 cues=float4(.30+.90*bar,.25+1.25*ripple*ripple,
        .25+1.20*checker,.25+1.20*sector*sector);
    float4 colors=float4(.5+.5*sin(cell.x*.35+latitude*2.-beatClock*.42),
        .5+.5*sin(radius*6.5-beatClock*PI*.5),checker,
        .5+.5*sin(angle*4.-beatClock*PI*.5));
    float2 extraCues=float2(.25+1.20*twin*twin,.25+1.20*spiral*spiral);
    float2 extraColors=float2(.5+.5*sin(abs(longitude)*4.+latitude*2.-beatClock*PI*.5),
        .5+.5*sin(angle*2.+radius*5.+beatClock*.6));
    float colorZone=dot(firstWeights,colors)+dot(extraWeights,extraColors);
    float accent=hash(cell+91.);
    float3 tint=mix(float3(.015,.82,1.45),float3(.40,.025,1.35),smoothstep(.30,.68,colorZone));
    tint=mix(tint,float3(1.40,.018,.76),smoothstep(.66,.94,colorZone));
    tint=mix(tint,float3(.48,1.08,1.5),step(.965,accent)*.42);
    float3 c=float3(.008,.012,.054);
    // Beat accents sit on the current scene, rather than becoming one
    // permanent diagonal color sweep across every lighting pattern.
    float beat=.5+.5*cos(beatClock*2.*PI);
    float kick=pow(beat,5.);
    float choreography=dot(firstWeights,cues)+dot(extraWeights,extraCues);
    float lightCue=choreography+.72*kick*(.35+.65*choreography);
    c+=tint*enabled*window*band*2.6*detail*lightCue;
    c+=float3(.025,.09,.16)*band*(1.-detail);
    float glow=exp(-dot(f-.5,f-.5)/.22)*enabled*tileFade;
    c+=tint*glow*band*.48*detail*(.45+.55*lightCue);
    c+=tint*band*(.018+.022*choreography);
    float columnWidth=max(.034,aa.x*.6);
    float columns=exp(-pow((f.x-.5)/columnWidth,2.))*.12*(.034/columnWidth);
    c+=float3(.05,.18,.4)*columns*band;
    return c;
}
// Arc length of the stable S centerline, integrated once at authoring time.
constant float neonFlowArc[129] = {
    0.00000000,0.01926506,0.03957086,0.06138022,0.08503217,0.11075107,
    0.13866551,0.16882766,0.20122960,0.23581580,0.27249266,0.31113564,
    0.35159475,0.39369893,0.43725960,0.48207367,0.52792628,0.57459313,
    0.62184281,0.66943888,0.71714198,0.76471185,0.81190934,0.85849847,
    0.90424849,0.94893602,0.99234736,1.03428089,1.07454977,1.11298504,
    1.14943928,1.18379103,1.21595045,1.24586673,1.27353779,1.29902331,
    1.32246134,1.34408792,1.36425544,1.38343990,1.40222278,1.42123898,
    1.44110404,1.46235033,1.48539435,1.51053431,1.53796440,1.56779373,
    1.60006362,1.63476149,1.67183148,1.71118233,1.75269344,1.79621957,
    1.84159459,1.88863465,1.93714083,1.98690162,2.03769510,2.08929102,
    2.14145279,2.19393944,2.24650747,2.29891280,2.35091255,2.40226700,
    2.45274146,2.50210824,2.55014864,2.59665510,2.64143343,2.68430539,
    2.72511142,2.76371403,2.80000185,2.83389465,2.86535000,2.89437196,
    2.92102274,2.94543773,2.96784373,2.98857731,3.00809514,3.02696268,
    3.04581011,3.06526211,3.08586913,3.10806643,3.13216599,3.15836894,
    3.18678513,3.21745199,3.25034994,3.28541419,3.32254366,3.36160766,
    3.40245114,3.44489882,3.48875861,3.53382458,3.57987953,3.62669739,
    3.67404542,3.72168637,3.76938049,3.81688759,3.86396906,3.91038990,
    3.95592083,4.00034045,4.04343752,4.08501351,4.12488529,4.16288840,
    4.19888081,4.23274761,4.26440699,4.29381811,4.32099150,4.34600282,
    4.36901033,4.39027475,4.41017621,4.42921713,4.44799660,4.46715171,
    4.48728398,4.50890141,4.53239338
};
float neonFlowArcAt(float y) {
    float at=clamp((y+1.2)*(128./2.4),0.,128.);
    uint i=min(uint(floor(at)),127u);
    return mix(neonFlowArc[i],neonFlowArc[i+1],at-float(i));
}
float3 neonFlow(float2 uv,float t,float px) {
    float2 at=(uv-.5)*2.;
    float bendPhase=at.y*4.+.20;
    float bend=.62*sin(bendPhase)+.14*at.y;
    float slope=2.48*cos(bendPhase)+.14;
    float metric=sqrt(1.+slope*slope);
    float d=(at.x-bend)/metric;
    float curvature=-9.92*sin(bendPhase)/(metric*metric*metric);
    float arc=neonFlowArcAt(at.y)+slope*d;
    float width=min(.115,.62/max(abs(curvature),.01));
    float lane=1.-smoothstep(width-px*2.,width+px*2.,abs(d));
    // Both the tiles and their light packets advect along arc length. The
    // normal/tangent chart turns them through the bends instead of blinking
    // stationary squares or translating a straight texture over the sphere.
    float across=d/.064+.5;
    float row=floor(across);
    float speed=.42*(.88+.20*hash(float2(row,11.7)));
    float2 grid=float2(across,(arc-t*speed)/.078+.22*sin(row*1.3));
    float2 cell=floor(grid),f=fract(grid);
    float curveScale=max(.35,abs(1.-curvature*d));
    float2 footprint=px*2.*float2(1./.064,1./(.078*curveScale));
    float2 aa=clamp(footprint,float2(.025),float2(.6));
    float detail=1.-smoothstep(.65,1.6,max(footprint.x,footprint.y));
    float2 coverage=clamp((float2(.38)-abs(f-.5))/aa+.5,0.,1.);
    float2 border=smoothstep(float2(0.),aa*.5,f)*smoothstep(float2(0.),aa*.5,1.-f);
    float square=coverage.x*coverage.y*border.x*border.y;
    float packet=.5+.5*cos((arc-t*.42)*(2.*PI/.85));
    float bright=(.25+.75*packet*packet)*(.65+.35*hash(cell));
    bright*=.65+.35*smoothstep(.25,.75,f.y);
    float3 cyan=float3(.015,.83,1.),pink=float3(1.,.065,.63);
    float colorWave=.5+.5*sin((arc-t*.42)*2.6+d*5.);
    float3 tint=mix(cyan,pink,smoothstep(.25,.78,colorWave));
    float3 c=float3(.004,.006,.034)+stars(uv,t,px)*.17;
    c+=tint*lane*square*bright*3.2*detail;
    c+=tint*exp(-pow(d/(width*1.3),2.))*(.035+.22*packet*packet)*(1.+.5*(1.-detail));
    // Sparse independently drifting blocks, distinct from the curved river grid.
    float2 particleGrid=uv*13.+float2(t*.035,-t*.095),particleCell=floor(particleGrid),pf=fract(particleGrid)-.5;
    float seed=hash(particleCell+37.);float halfWidth=.06+.14*hash(particleCell+11.);
    float particleAA=max(.025,px*13.);
    float2 block=clamp((halfWidth-abs(pf))/particleAA+.5,0.,1.);
    float particle=step(.87,seed)*smoothstep(width*1.2,width*1.8,abs(d));
    float3 particleTint=mix(cyan,pink,hash(particleCell+53.));
    c+=particleTint*particle*block.x*block.y*(1.4+.45*sin(t*.6+seed*15.));
    c+=particleTint*particle*exp(-dot(pf,pf)/(.018+halfWidth*.12))*.18;
    return c;
}
float3 siri(float2 uv,float t,float px) {
    float2 p=(uv-.5)*2.;float3 c=float3(.002,.009,.04);
    // Projected, tilted ellipsoidal membranes. Their broad clear interiors and
    // luminous silhouettes overlap additively, with a compact common light core.
    for(int j=0;j<4;j++) {
        float f=float(j),phase=t*.34+f*1.57;
        float angle=(j==0?.65:j==1?-.85:j==2?1.05:.75)+.24*sin(t*.26+f);
        float2 center=(j==0?float2(-.15,0.):j==1?float2(-.16,.28):j==2?float2(.27,-.14):float2(0.,.05));
        center+=float2(.045*cos(phase),.04*sin(phase));
        float2 q=rotate2(p-center,angle);
        float a=(j==1||j==2?.77:.93)+.045*sin(phase),b=(j==2?.28:.38)+.045*cos(phase*.7);
        q.y+=.07*sin(q.x*3.+phase);
        float2 e=q/float2(a,b);float rr=length(e);
        float aa=max(.005,px*2.);
        float mask=1.-smoothstep(1.-aa,1.+aa,rr);
        float z=sqrt(max(.002,1.-rr*rr));
        float3 n=normalize(float3(e*.5,z));
        float rim=pow(1.-z,3.);
        float3 tone=j==0?float3(.065,.32,1.):j==1?float3(.025,.77,.58):j==2?float3(.92,.07,.56):float3(.04,.60,1.);
        float front=.6+.4*max(0.,dot(n,normalize(float3(-.5,-.4,1.))));
        float alpha=.22+.30*z+.12*rim;
        float3 face=tone*(.28+.60*z+.30*rim)*front;
        c=mix(c,face,mask*alpha);
        c+=tone*mask*z*.06;
        float width=.015+aa*.65;
        float edge=exp(-pow((rr-.99)/width,2.))*.015/width;
        c+=mix(tone,float3(.8,.9,1.),.16)*edge*.60;
        c+=tone*exp(-pow((rr-1.)/.08,2.))*.10;
        float sheen=pow(max(0.,dot(n,normalize(float3(-.5,-.5,1.)))),20.);
        c+=float3(.7,.9,1.)*sheen*.14*mask;
    }
    float2 core=float2(.26+.03*sin(t*.34),.29+.025*cos(t*.29));
    c+=float3(.30,.85,1.2)*halo(p,core,.20)*(1.25+.15*sin(t*.9));
    c+=float3(1.,.91,1.)*halo(p,core,.067)*3.1;
    return c;
}

float3 camouflage(float2 uv,float t,float px,texture3d<float> field) {
    float2 p=(uv-.5)*2.;float z=sqrt(max(.001,1.-dot(p,p)));
    float3 n=float3(p,z),q=n;
    q.xz=rotate2(q.xz,t*.13);q.yz=rotate2(q.yz,.10*sin(t*.31));
    float footprint=px*10./max(z,.2);
    float3 at=q*5.0+17.;
    float3 warp=(volumeField(field,at*.60,footprint*.60).gba-.5)*1.5;
    float4 sample=volumeField(field,at+warp,footprint);
    float shape=.72*sample.r+.28*volumeField(field,at*1.8+7.,footprint*1.8).g;
    float aa=max(.025,px*.7);
    float3 c=mix(float3(.045,.083,.028),float3(.17,.22,.070),smoothstep(.36-aa,.36+aa,shape));
    c=mix(c,float3(.40,.35,.15),smoothstep(.59-aa,.59+aa,shape));
    c=mix(c,float3(.028,.054,.020),smoothstep(.60-aa,.60+aa,sample.b)*.85);
    float diffuse=.30+.70*max(0.,dot(n,normalize(float3(-.45,-.65,.90))));
    float weave=.92+.08*sin(q.y*135.)*sin(q.x*135.);
    weave=mix(weave,1.,smoothstep(.25,.75,px*135.));
    c*=diffuse*weave;
    c+=float3(.12,.16,.060)*pow(1.-z,4.)*.20;
    return c;
}

float3 glassBall(float2 uv,float t,float px,texture3d<float> field) {
    float2 p=(uv-.5)*2.;float z=sqrt(max(.001,1.-dot(p,p)));
    float3 n=float3(p,z),reflection=reflect(float3(0.,0.,-1.),n);
    float3 q=reflection;q.xz=rotate2(q.xz,t*.16);
    float3 c=mix(float3(.012,.036,.095),float3(.090,.16,.29),.5+.5*n.y);
    c+=float3(.12,.032,.20)*exp(-dot(p-float2(.38,.35),p-float2(.38,.35))/.40);
    float cloud=volumeField(field,n*3.+float3(t*.027,8.,11.),px*6.).b;
    c+=float3(.025,.12,.18)*cloud*.45;
    float a=exp(-(1.-dot(q,normalize(float3(-.60,-.52,.70))))/.12);
    float b=exp(-(1.-dot(q,normalize(float3(.65,.20,.70))))/.025);
    float d=exp(-(1.-dot(q,normalize(float3(-.30,.80,-.50))))/.07);
    float fresnel=.08+.92*pow(1.-z,3.);
    c+=float3(.65,.86,1.05)*a*(.40+fresnel*1.8);
    c+=float3(.58,.30,.95)*b*(.45+fresnel*2.0);
    c+=float3(.12,.80,.88)*d*(.30+fresnel);
    float radius=length(p);float2 direction=p/max(radius,.001);
    float2 lamp=rotate2(normalize(float2(-.65,-.75)),t*.12);
    float arcWidth=max(.014,px*1.5);
    float arc=exp(-pow((radius-.84)/arcWidth,2.))*.014/arcWidth*pow(max(0.,dot(direction,lamp)),10.);
    float inner=exp(-pow((radius-.70)/max(.035,px*1.5),2.))*pow(max(0.,dot(direction,lamp)),18.);
    c+=float3(.72,.91,1.1)*(arc*.95+inner*.16);
    float glint=exp(-(1.-dot(q,normalize(float3(-.70,-.70,-.10))))/max(.0035,px*.24));
    c+=float3(.80,.95,1.1)*glint*2.1;
    // Thin-film edge reflections remain attached to the sphere normal.
    float3 film=.50+.50*cos((1.-z)*12.+cloud*.8+float3(.0,2.1,4.2));
    c+=film*pow(1.-z,4.)*.38;
    float edgeWidth=max(.010,px*1.3);
    c+=float3(.22,.61,.84)*exp(-pow((length(p)-.985)/edgeWidth,2.))*.010/edgeWidth;
    return c;
}


// Shared jittered corners keep neighboring ceramic tiles joined at the seam.
// Canonical longitude IDs also preserve the pattern when a full turn wraps.
float2 mosaicCorner(float2 id) {
    float2 key=float2(id.x-floor(id.x/100.)*100.,id.y);
    return id+(float2(hash(key+19.7),hash(key+73.1))-.5)*.34;
}
float mosaicEdge(float2 p,float2 a,float2 b) {
    float2 e=b-a;return (e.x*(p.y-a.y)-e.y*(p.x-a.x))/length(e);
}
float3 mosaicTile(float2 tileID,float3 n,float2 p,float distance,float aa) {
    float2 key=float2(tileID.x-floor(tileID.x/100.)*100.,tileID.y);
    float seed=hash(key+3.7),variation=hash(key+47.3);
    float2 slope=(float2(hash(key+11.1),hash(key+91.4))-.5)*.34;
    float3 tangent=normalize(float3(n.z,0.,-n.x));
    float3 bitangent=normalize(cross(n,tangent));
    float3 facet=normalize(n+tangent*slope.x+bitangent*slope.y);
    float3 light=normalize(float3(.48,-.55,1.));
    float warm=exp(-dot(p-float2(.38,-.48),p-float2(.38,-.48))/.24);
    float pale=smoothstep(.74,.94,seed);
    float3 cool=mix(float3(.005,.023,.040),float3(.023,.29,.32),pow(seed,.72));
    cool=mix(cool,float3(.40,.46,.38),pale*.82);
    float3 gold=mix(float3(.65,.012,.002),float3(1.05,.40,.018),variation);
    gold=mix(gold,float3(.83,.74,.42),pale*.75);
    float3 tile=mix(cool,gold,min(1.,warm*1.25)*(.85+.15*hash(key+62.)));
    float diffuse=.13+.87*max(0.,dot(facet,light));
    float sheen=pow(max(0.,dot(facet,normalize(light+float3(0,0,1)))),55.);
    float fill=exp(-dot(p-float2(.14,.15),p-float2(.14,.15))/.13);
    tile*=diffuse*(.65+.55*variation);
    tile+=float3(.65,.83,.80)*sheen*(.12+.52*variation)+float3(.27,.45,.39)*fill*pale*.42;
    float bevel=exp(-pow((distance-.075)/max(.026,aa),2.))*.026/max(.026,aa);
    tile+=float3(.14,.20,.19)*bevel*(.4+.6*variation);
    return tile;
}
float3 mosaicBall(float2 uv,float t,float px) {
    float2 p=(uv-.5)*2.;float z=sqrt(max(.0001,1.-dot(p,p)));
    float3 n=normalize(float3(p,z)),q=n;
    // Steady rotation, with the reflection light fixed in the room.
    q.yz=rotate2(q.yz,.16);q.xz=rotate2(q.xz,t*.065);
    float2 grid=float2((atan2(q.x,q.z)+PI)*100./(2.*PI),(asin(clamp(q.y,-1.,1.))+PI*.5)*54./PI);
    float2 origin=floor(grid);float3 color=0.;float total=0.,coverage=0.;
    float aa=clamp(px*36./max(z,.20),.012,1.25);
    // Filter both the tile color and its grout across display-pixel boundaries.
    // Selecting one nearest tile would make bright facets pop even with AA grout.
    for(int y=-1;y<=1;y++)for(int x=-1;x<=1;x++) {
        float2 id=origin+float2(x,y);
        float2 a=mosaicCorner(id),b=mosaicCorner(id+float2(1,0));
        float2 c=mosaicCorner(id+1.),d=mosaicCorner(id+float2(0,1));
        float inside=min(min(mosaicEdge(grid,a,b),mosaicEdge(grid,b,c)),min(mosaicEdge(grid,c,d),mosaicEdge(grid,d,a)));
        float weight=smoothstep(-aa,aa,inside);
        if(weight>.0001) {
            color+=mosaicTile(id,n,p,inside,aa)*weight;
            total+=weight;
            coverage+=smoothstep(.035-aa,.035+aa,inside);
        }
    }
    float3 grout=float3(.002,.008,.014)*(.35+.65*z);
    return mix(grout,color/max(total,.0001),clamp(coverage/max(total,.0001),0.,1.));
}

// Radial projection of an exact truncated icosahedron: twelve pentagons and
// twenty hexagons. Face normals and plane distances are precomputed constants.
// Negative distances identify the black pentagonal panels.
constant float4 soccerPlanes[32] = {
+    float4(0.000000000,-0.525731112,-0.850650808,-0.815737865),
    float4(-0.525731112,-0.850650808,0.000000000,-0.815737865),
    float4(-0.850650808,0.000000000,-0.525731112,-0.815737865),
    float4(0.000000000,-0.525731112,0.850650808,-0.815737865),
    float4(-0.525731112,0.850650808,0.000000000,-0.815737865),
    float4(0.850650808,0.000000000,-0.525731112,-0.815737865),
    float4(0.000000000,0.525731112,-0.850650808,-0.815737865),
    float4(0.525731112,-0.850650808,0.000000000,-0.815737865),
    float4(-0.850650808,0.000000000,0.525731112,-0.815737865),
    float4(0.000000000,0.525731112,0.850650808,-0.815737865),
    float4(0.525731112,0.850650808,0.000000000,-0.815737865),
    float4(0.850650808,0.000000000,0.525731112,-0.815737865),
    float4(-0.577350269,-0.577350269,-0.577350269,0.794654472),
    float4(0.000000000,-0.934172359,-0.356822090,0.794654472),
    float4(-0.356822090,0.000000000,-0.934172359,0.794654472),
    float4(0.356822090,0.000000000,-0.934172359,0.794654472),
    float4(0.577350269,-0.577350269,-0.577350269,0.794654472),
    float4(-0.934172359,-0.356822090,0.000000000,0.794654472),
    float4(0.000000000,-0.934172359,0.356822090,0.794654472),
    float4(-0.577350269,-0.577350269,0.577350269,0.794654472),
    float4(-0.577350269,0.577350269,-0.577350269,0.794654472),
    float4(-0.934172359,0.356822090,0.000000000,0.794654472),
    float4(0.577350269,-0.577350269,0.577350269,0.794654472),
    float4(-0.356822090,0.000000000,0.934172359,0.794654472),
    float4(0.356822090,0.000000000,0.934172359,0.794654472),
    float4(0.000000000,0.934172359,-0.356822090,0.794654472),
    float4(-0.577350269,0.577350269,0.577350269,0.794654472),
    float4(0.000000000,0.934172359,0.356822090,0.794654472),
    float4(0.577350269,0.577350269,-0.577350269,0.794654472),
    float4(0.934172359,-0.356822090,0.000000000,0.794654472),
    float4(0.934172359,0.356822090,0.000000000,0.794654472),
    float4(0.577350269,0.577350269,0.577350269,0.794654472)
};

// Eight complete glance clips: four retained exploration motifs and four lively
// variations. Neutral endpoints and zero-velocity easing join arbitrary clips.
constant float4 pokeballGlanceTargets[48] = {
    // Clip 0: time, yaw, pitch, roll.
    float4(0.0000,0.0000,0.0000,0.0000), 
    float4(2.5000,0.5200,-0.1000,-0.0450), 
    float4(5.0000,0.3200,-0.3400,-0.0250), 
    float4(7.5000,-0.4600,-0.2200,0.0550), 
    float4(10.0000,-0.1200,-0.0800,0.0150), 
    float4(12.0000,0.0000,0.0000,0.0000), 
    // Clip 1: time, yaw, pitch, roll.
    float4(0.0000,0.0000,0.0000,0.0000), 
    float4(2.5000,-0.5600,0.1800,0.0400), 
    float4(5.0000,-0.1200,0.3400,0.0100), 
    float4(7.5000,0.4800,0.2000,-0.0450), 
    float4(10.0000,0.1800,0.0800,-0.0150), 
    float4(12.0000,0.0000,0.0000,0.0000), 
    // Clip 2: time, yaw, pitch, roll.
    float4(0.0000,0.0000,0.0000,0.0000), 
    float4(2.5000,0.1000,-0.3800,-0.0150), 
    float4(5.0000,-0.4800,-0.0400,0.0550), 
    float4(7.5000,0.1800,-0.1200,-0.0250), 
    float4(10.0000,0.5400,0.0500,-0.0500), 
    float4(12.0000,0.0000,0.0000,0.0000), 
    // Clip 3: time, yaw, pitch, roll.
    float4(0.0000,0.0000,0.0000,0.0000), 
    float4(2.5000,-0.3200,0.2200,0.0450), 
    float4(5.0000,-0.1200,0.3400,0.0100), 
    float4(7.5000,0.3200,0.1600,-0.0350), 
    float4(10.0000,0.1800,-0.1000,-0.0150), 
    float4(12.0000,0.0000,0.0000,0.0000), 
    // Clip 4: time, yaw, pitch, roll.
    float4(0.0000,0.0000,0.0000,0.0000), 
    float4(1.5000,0.2500,-0.0600,-0.0500), 
    float4(3.0000,0.0600,0.0250,0.0200), 
    float4(5.8000,0.5200,-0.1600,-0.0850), 
    float4(8.8000,0.4000,-0.1000,-0.0450), 
    float4(12.0000,0.0000,0.0000,0.0000), 
    // Clip 5: time, yaw, pitch, roll.
    float4(0.0000,0.0000,0.0000,0.0000), 
    float4(2.2000,-0.2400,0.1600,0.1050), 
    float4(4.4000,-0.4000,0.2600,0.1350), 
    float4(6.8000,-0.1600,0.3000,0.0750), 
    float4(9.2000,0.2200,0.1800,-0.0550), 
    float4(12.0000,0.0000,0.0000,0.0000), 
    // Clip 6: time, yaw, pitch, roll.
    float4(0.0000,0.0000,0.0000,0.0000), 
    float4(2.4000,-0.3400,-0.2200,0.0550), 
    float4(4.8000,-0.1000,-0.4000,0.0200), 
    float4(7.2000,0.3200,-0.3000,-0.0650), 
    float4(9.6000,0.4000,-0.1000,-0.0350), 
    float4(12.0000,0.0000,0.0000,0.0000), 
    // Clip 7: time, yaw, pitch, roll.
    float4(0.0000,0.0000,0.0000,0.0000), 
    float4(2.2000,0.2200,-0.1200,-0.1150), 
    float4(4.4000,0.1000,-0.1000,0.0750), 
    float4(6.8000,-0.3400,-0.0400,0.1300), 
    float4(9.2000,-0.4600,0.0800,0.0550), 
    float4(12.0000,0.0000,0.0000,0.0000), 
};
// Each shuffled round visits all eight clips once. The first/last groups
// differ, so neighboring rounds cannot repeat the same clip.
constant uchar pokeballGlanceOrders[192] = {
    2,7,0,3,1,4,6,5,
    2,1,0,4,5,6,3,7,
    3,1,5,2,7,0,6,4,
    2,3,6,7,0,1,4,5,
    3,5,7,2,1,0,6,4,
    2,0,5,6,4,1,3,7,
    0,3,7,5,1,4,2,6,
    2,6,1,0,5,4,3,7,
    2,7,4,5,3,1,0,6,
    2,5,0,1,7,6,3,4,
    0,1,3,2,6,5,7,4,
    2,7,3,1,0,5,6,4,
    2,5,3,6,0,1,4,7,
    0,4,6,1,5,2,3,7,
    1,7,6,3,0,2,5,4,
    2,3,7,0,1,6,4,5,
    1,3,0,5,4,2,7,6,
    1,4,3,6,0,2,7,5,
    3,1,7,4,2,5,0,6,
    0,6,2,3,7,1,4,5,
    1,2,6,7,3,0,5,4,
    0,7,2,5,3,4,1,6,
    0,1,5,6,3,2,4,7,
    2,0,3,5,1,4,6,7,
};
uint pokeballGlanceAt(uint slot) {
    uint round=slot/8;
    uint seed=round*747796405u+2891336453u;
    seed=((seed>>((seed>>28u)+4u))^seed)*277803737u;
    seed=(seed>>22u)^seed;
    return uint(pokeballGlanceOrders[(seed%24u)*8u+slot%8u]);
}
float3 pokeballLook(float t) {
    float clock=max(t,0.)/12.;
    uint clip=pokeballGlanceAt(uint(floor(clock)));
    float phase=fract(clock)*12.;
    uint base=clip*6u,index=0u;
    for(uint i=1u;i<5u;i++)if(phase>=pokeballGlanceTargets[base+i].x)index=i;
    float4 a=pokeballGlanceTargets[base+index],b=pokeballGlanceTargets[base+index+1u];
    float u=clamp((phase-a.x)/min(2.10,(b.x-a.x)*.88),0.,1.);
    float eased=u*u*u*(u*(u*6.-15.)+10.);
    float3 look=mix(a.yzw,b.yzw,eased);
    look.xy+=float2(sin(t*1.7)*.009,sin(t*1.1)*.007);
    return look;
}

float3 rotatingBall(float2 uv,float t,float px,uint kind,texture3d<float> field) {
    float2 p=(uv-.5)*2.;float z=sqrt(max(.0001,1.-dot(p,p)));
    float3 n=normalize(float3(p,z)),q=n;
    float aa=max(.002,px*2./max(z,.32));
    float3 albedo;float seam=0.;float specular=.08;float grain=1.;
    if(kind==12) {
        q.xz=rotate2(q.xz,t*.10);q.yz=rotate2(q.yz,.553574);
        float best=-10.,second=-10.;int primary=0,neighbor=0;
        for(int i=0;i<32;i++) {
            float score=dot(q,soccerPlanes[i].xyz)/abs(soccerPlanes[i].w);
            if(score>best){second=best;neighbor=primary;best=score;primary=i;}
            else if(score>second){second=score;neighbor=i;}
        }
        float3 delta=soccerPlanes[primary].xyz/abs(soccerPlanes[primary].w)-soccerPlanes[neighbor].xyz/abs(soccerPlanes[neighbor].w);
        float edge=(best-second)/max(length(delta),.001);
        float3 black=float3(.006,.008,.013),white=float3(.72,.76,.73);
        float3 a=soccerPlanes[primary].w<0.?black:white,b=soccerPlanes[neighbor].w<0.?black:white;
        albedo=mix(b,a,smoothstep(-aa,aa,edge));
        seam=1.-smoothstep(.004-aa*.6,.007+aa*.6,edge);
        grain=.96+.04*volumeField(field,q*70.+19.,px*140./max(z,.3)).r;
        specular=.10;
    } else if(kind==13) {
        q.xz=rotate2(q.xz,t*.15+.35);q.yz=rotate2(q.yz,.25);
        // Continuous grooves follow the surface, so the curves foreshorten
        // naturally instead of sliding as a flat screen-space decoration.
        float groove=min(abs(q.y),min(abs(q.x),abs(abs(q.z)-.58)));
        seam=1.-smoothstep(.013-aa*.55,.018+aa*.55,groove);
        float pebble=volumeField(field,q*90.+7.,px*180./max(z,.30)).g;
        grain=.72+.40*smoothstep(.24,.74,pebble);
        albedo=float3(.95,.13,.015);
        specular=.045;
    } else {
        float3 look=pokeballLook(t);
        q.xy=rotate2(q.xy,-look.z);
        q.yz=rotate2(q.yz,look.y);
        q.xz=rotate2(q.xz,look.x);
        float top=1.-smoothstep(-aa,aa,q.y);
        albedo=mix(float3(.78,.76,.84),float3(.72,.008,.018),top);
        float band=1.-smoothstep(.073-aa,.073+aa,abs(q.y));
        float button=acos(clamp(q.z,-1.,1.));
        float blackDisk=1.-smoothstep(.345-aa,.345+aa,button);
        float whiteDisk=1.-smoothstep(.244-aa,.244+aa,button);
        float innerRing=(1.-smoothstep(.200-aa,.200+aa,button))*smoothstep(.181-aa,.181+aa,button);
        albedo=mix(albedo,float3(.0025,.003,.004),max(band,blackDisk));
        albedo=mix(albedo,float3(.86,.86,.90),whiteDisk);
        albedo=mix(albedo,float3(.008,.009,.012),innerRing);
        specular=.22;
    }
    float3 light=normalize(float3(-.48,-.60,1.));
    float diffuse=.17+.83*max(0.,dot(n,light));
    float3 color=albedo*diffuse*grain;
    if(kind==12)color=mix(color,float3(.014,.018,.020)*diffuse,seam*.62);
    if(kind==13)color=mix(color,float3(.075,.028,.009)*diffuse,seam);
    float gloss=pow(max(0.,dot(n,normalize(light+float3(0,0,1)))),kind==14?95.:45.);
    color+=float3(.85,.91,1.)*gloss*specular;
    color+=albedo*.035*pow(1.-z,3.);
    return color;
}

float3 materialTone(float3 c) {
    c=max(c,float3(0.));
    c=clamp((c*(2.51*c+.03))/(c*(2.43*c+.59)+.14),0.,1.);
    return select(c*12.92,1.055*pow(c,float3(1./2.4))-.055,c>.0031308);
}
float3 polish(float3 c,float2 uv,uint kind,float t,float px){
    if(kind==3)return 1.-exp(-max(c,float3(0.))*1.35);
    if(kind==9)return materialTone(c*1.3);
    if(kind==10)return materialTone(c);
    if(kind==11)return materialTone(c);
    if(kind>=12&&kind<=14)return materialTone(c);
    float2 p=(uv-.5)*2.;float r=length(p),z=sqrt(max(.001,1.-dot(p,p)));
    float3 n=float3(p,z),light=normalize(float3(-.49,-.64,1.));
    float fresnel=pow(1.-z,3.);
    float3 rim=float3(.12,.43,1.);
    if(kind==0)rim=.8+.65*cos(atan2(p.y,p.x)+float3(.3,2.4,4.5)+t*.07);
    if(kind==1)rim=mix(float3(.05,.9,.76),float3(.57,.16,.95),smoothstep(-.7,.8,p.x));
    if(kind==2)rim=float3(.1,.85,1.);
    // Curved reflection of a broad environment light, plus a narrow glass edge.
    float softbox=pow(max(0.,dot(n,light)),28.);
    float rimWidth=max(.009,px*1.3);float edge=exp(-pow((r-.986)/rimWidth,2.))*.009/rimWidth;
    float arc=exp(-pow((r-.93)/.035,2.))*pow(max(0.,dot(p/max(r,.0001),normalize(float2(-.5,-.8)))),12.);
    c*=.70+.30*z;
    c+=rim*fresnel*.68+mix(rim,float3(.85,.96,1.),.3)*edge*.85;
    c+=float3(.7,.88,1.)*(softbox*(kind==0?1.1:.18)+arc*.9);
    float2 glint=float2(-.56,-.73)+float2(.018*sin(t*.13),.008*cos(t*.16));
    float2 delta=p-glint;
    c+=float3(.65,.86,1.)*(halo(p,glint,.017)*3.+halo(p,glint,.068)*.30);
    c+=float3(.65,.90,1.)*(exp(-abs(delta.x)*330.)*exp(-abs(delta.y)*45.)+exp(-abs(delta.y)*330.)*exp(-abs(delta.x)*45.))*.5;
    // Filmic shoulder preserves colored highlights instead of clipping them to flat white.
    if(kind==0||kind==1||kind==2||kind==4||kind==5||kind==8)return materialTone(c*.90);
    return 1.-exp(-max(c,float3(0.))*1.35);
}


float3 evaluateMaterial(uint kind,float2 uv,float t,float px,texture3d<float> field) {
    switch(kind){
        case 0:return rainbowBall(uv,t,px,field);
        case 1:return aurora(uv,t,false,px);
        case 2:return aurora(uv,t,true,px);
        case 3:return float3(0.); // StarRingRenderer owns the HDR scene and composite.
        case 4:return nebula(uv,t,false,px,field);
        case 5:return nebula(uv,t,true,px,field);
        case 6:return neonCity(uv,t,px);
        case 7:return neonFlow(uv,t,px);
        case 8:return siri(uv,t,px);
        case 9:return camouflage(uv,t,px,field);
        case 10:return glassBall(uv,t,px,field);
        case 11:return mosaicBall(uv,t,px);
        case 12:case 13:case 14:return rotatingBall(uv,t,px,kind,field);
    }
    return float3(0.);
}
kernel void materialFrame(texture2d<float,access::write> output [[texture(0)]],constant Parameters &args [[buffer(0)]],texture3d<float> field [[texture(1)]],uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=args.size||gid.y>=args.size)return;
    float2 uv=(float2(gid)+.5)/float(args.size);
    output.write(float4(clamp(polish(evaluateMaterial(args.kind,uv,args.time,args.footprint,field),uv,args.kind,args.time,args.footprint),0.,1.),1),gid);
}
struct LiveParameters {
    float time;uint kind;float2 size;float2 center;float2 scale;
    float rotation;float progress;uint style;float padding;float4 monochrome;
};
struct MaterialVertex {float4 position [[position]];float2 uv;};
vertex MaterialVertex materialVertex(uint id [[vertex_id]]) {
    float2 uv=id==0?float2(0,0):id==1?float2(2,0):float2(0,2);
    MaterialVertex out;out.position=float4(uv.x*2.-1.,1.-uv.y*2.,0,1);out.uv=uv;return out;
}

fragment float4 liveMaterialFragment(MaterialVertex in [[stage_in]],constant LiveParameters &args [[buffer(0)]],texture3d<float> field [[texture(0)]]) {
    float2 q=in.uv*args.size-args.center;
    float co=cos(args.rotation),si=sin(args.rotation);
    q=float2(q.x*co+q.y*si,-q.x*si+q.y*co)/args.scale;
    float2 local=q+114.27;
    float edge=length(q);
    float2 uv=local/228.54;
    float footprint=args.padding>0.?args.padding:max(length(dfdx(uv)),length(dfdy(uv)))*2.;
    float aa=max(.05,228.54*footprint);
    float distance=edge-114.27;
    float coverage=1.-smoothstep(-aa*.5,aa*.5,distance);
    float r=edge/114.27;
    float haloAlpha=exp(-pow(distance/6.285,2.))*.055*args.progress;
    float3 haloTint=args.kind==0?mix(float3(1.,.65,.18),float3(.35,.65,1.),smoothstep(-80.,80.,q.x)):
        args.kind==1?mix(float3(.08,.75,.48),float3(.65,.20,.92),smoothstep(-70.,70.,q.x)):
        args.kind==6||args.kind==7?mix(float3(.1,.7,1.),float3(1.,.15,.65),smoothstep(-70.,70.,q.x)):
        args.kind==9?float3(.22,.40,.11):args.kind==11?float3(.12,.48,.52):
        args.kind==12?float3(.45,.49,.52):args.kind==13?float3(.82,.36,.10):
        args.kind==14?mix(float3(.70,.09,.12),float3(.55,.53,.64),smoothstep(-40.,40.,q.y)):float3(.22,.55,1.);
    float3 haloColor=haloTint*haloAlpha;
    if(coverage<=0.) {
        if(haloAlpha<.0005)discard_fragment();
        return float4(haloColor,haloAlpha);
    }
    float amount=args.progress;
    if(args.style==0u&&edge>165.*amount&&amount<1.)discard_fragment();
    if(args.style==1u&&length(local)>325.*amount&&amount<1.)discard_fragment();
    if(args.style==2u&&amount<1.){
        float angle=atan2(q.y,q.x);if(angle<0.)angle+=2.*PI;
        float part=floor(angle/(PI/16.));
        float a=part*PI/16.,b=a+PI/16.;
        float ra=fmod(part,2.)<.5?185.:135.;float rb=320.-ra;
        float2 v0=float2(cos(a),sin(a))*ra,v1=float2(cos(b),sin(b))*rb;
        float2 ray=float2(cos(angle),sin(angle)),d=v1-v0;
        float radius=abs((v0.x*v1.y-v0.y*v1.x)/(ray.x*d.y-ray.y*d.x));
        if(edge>radius*amount)discard_fragment();
    }
    float3 col=clamp(polish(evaluateMaterial(args.kind,uv,args.time,footprint,field),uv,args.kind,args.time,footprint),0.,1.);
    if(args.style==3u)col=mix(args.monochrome.rgb,col,amount);
    col+=float3((hash(floor(in.position.xy))-.5)/255.);
    float alpha=coverage+haloAlpha*(1.-coverage);
    return float4(clamp(col,0.,1.)*coverage+haloColor*(1.-coverage),alpha);
}
