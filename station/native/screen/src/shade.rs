// The scaler where the GPU has no video processor (Microsoft's Basic Render Driver: a Windows 365 Cloud PC, a VM
// without a GPU; its device answers E_NOINTERFACE for ID3D11VideoDevice): pixel shaders draw the part of the picture
// into the view's size, as BGRA, or as NV12 the way the video processor makes it (BT.709, studio range) through the
// NV12 texture's two planes' render target views (R8 the luma, R8G8 the chroma at half the size). Shrunk, each pixel
// the mean of four bilinear taps over what it covers, so text keeps its strokes.
use windows::Win32::Graphics::Direct3D::Fxc::D3DCompile;
use windows::Win32::Graphics::Direct3D::{D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST, D3D11_SRV_DIMENSION_TEXTURE2D, ID3DBlob};
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::core::{PCSTR, Result, s};

const SHADER: &str = r"
Texture2D<float4> picture : register(t0);
SamplerState linear_clamp : register(s0);
// As fractions of the picture: the part drawn (left, top, width, height), a target pixel's size, a picture pixel's.
cbuffer Part : register(b0) { float4 part; float2 pixel; float2 texel; };

struct Out { float4 at : SV_POSITION; float2 uv : TEXCOORD0; };

Out vs(uint id : SV_VertexID) {
    // One triangle over the whole target.
    float2 uv = float2((id << 1) & 2, id & 2);
    Out o;
    o.at = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    o.uv = uv;
    return o;
}

// A bilinear tap, kept to the part's own pixels (what is beside a part framed alone is not blended in at its edges).
float3 tap(float2 at) {
    return picture.SampleLevel(linear_clamp, clamp(at, part.xy + texel * 0.5, part.xy + part.zw - texel * 0.5), 0).rgb;
}

// The colour over a target pixel `size` (of one target pixel) wide: four bilinear taps a quarter in from its corners.
float3 colour(float2 uv, float size) {
    float2 at = part.xy + uv * part.zw;
    float2 d = pixel * size * 0.25;
    return (tap(at + float2(-d.x, -d.y)) + tap(at + float2(d.x, -d.y)) + tap(at + float2(-d.x, d.y)) + tap(at + float2(d.x, d.y))) * 0.25;
}

float4 bgra(Out i) : SV_TARGET {
    return float4(colour(i.uv, 1), 1);
}

float luma(Out i) : SV_TARGET {
    return 16.0 / 255 + dot(colour(i.uv, 1), float3(0.2126, 0.7152, 0.0722)) * (219.0 / 255);
}

float2 chroma(Out i) : SV_TARGET {
    float3 c = colour(i.uv, 2);
    return 128.0 / 255 + float2(dot(c, float3(-0.1146, -0.3854, 0.5)), dot(c, float3(0.5, -0.4542, -0.0458))) * (224.0 / 255);
}
";

fn compile(entry: PCSTR, target: PCSTR) -> Result<ID3DBlob> {
    let mut code = None;
    unsafe { D3DCompile(SHADER.as_ptr().cast(), SHADER.len(), None, None, None, entry, target, 0, 0, &mut code, None)? };
    Ok(code.unwrap())
}

fn bytes(blob: &ID3DBlob) -> &[u8] {
    unsafe { std::slice::from_raw_parts(blob.GetBufferPointer() as *const u8, blob.GetBufferSize()) }
}

/// The shaders for one output format (BGRA, or NV12's two planes).
pub struct Shade {
    vs: ID3D11VertexShader,
    /// The pixel shaders, each with the format of the view it draws into: BGRA's one, or NV12's luma then chroma.
    ps: Vec<(ID3D11PixelShader, DXGI_FORMAT)>,
    sampler: ID3D11SamplerState,
    constants: ID3D11Buffer,
}

impl Shade {
    pub fn new(device: &ID3D11Device, format: DXGI_FORMAT) -> Result<Shade> {
        if format == DXGI_FORMAT_NV12 {
            let support = unsafe { device.CheckFormatSupport(DXGI_FORMAT_NV12)? };
            if support & D3D11_FORMAT_SUPPORT_RENDER_TARGET.0 as u32 == 0 {
                return Err(windows::core::Error::new(windows::Win32::Foundation::E_NOTIMPL, "this GPU has no video processor and cannot draw into NV12"));
            }
        }
        let shaders: &[(PCSTR, DXGI_FORMAT)] = if format == DXGI_FORMAT_NV12 { &[(s!("luma"), DXGI_FORMAT_R8_UNORM), (s!("chroma"), DXGI_FORMAT_R8G8_UNORM)] } else { &[(s!("bgra"), format)] };
        let vs_code = compile(s!("vs"), s!("vs_4_0"))?;
        let (mut vs, mut sampler, mut constants) = (None, None, None);
        let mut ps = Vec::new();
        unsafe {
            device.CreateVertexShader(bytes(&vs_code), None, Some(&mut vs))?;
            for (entry, view) in shaders {
                let mut made = None;
                device.CreatePixelShader(bytes(&compile(*entry, s!("ps_4_0"))?), None, Some(&mut made))?;
                ps.push((made.unwrap(), *view));
            }
            let desc = D3D11_SAMPLER_DESC {
                Filter: D3D11_FILTER_MIN_MAG_MIP_LINEAR,
                AddressU: D3D11_TEXTURE_ADDRESS_CLAMP,
                AddressV: D3D11_TEXTURE_ADDRESS_CLAMP,
                AddressW: D3D11_TEXTURE_ADDRESS_CLAMP,
                MaxLOD: f32::MAX,
                ..Default::default()
            };
            device.CreateSamplerState(&desc, Some(&mut sampler))?;
            let desc = D3D11_BUFFER_DESC { ByteWidth: 32, Usage: D3D11_USAGE_DEFAULT, BindFlags: D3D11_BIND_CONSTANT_BUFFER.0 as u32, ..Default::default() };
            device.CreateBuffer(&desc, None, Some(&mut constants))?;
        }
        Ok(Shade { vs: vs.unwrap(), ps, sampler: sampler.unwrap(), constants: constants.unwrap() })
    }

    /// `crop` of `source` (BGRA, a shader resource; left, top, width, height in its pixels) drawn into `target` (`to`).
    pub fn run(&mut self, device: &ID3D11Device, context: &ID3D11DeviceContext, source: &ID3D11Texture2D, crop: (u32, u32, u32, u32), target: &ID3D11Texture2D, to: (u32, u32)) -> Result<()> {
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        unsafe { source.GetDesc(&mut desc) };
        let (w, h) = (desc.Width as f32, desc.Height as f32);
        let (x, y, cw, ch) = (crop.0 as f32, crop.1 as f32, crop.2 as f32, crop.3 as f32);
        let constants = [x / w, y / h, cw / w, ch / h, cw / w / to.0 as f32, ch / h / to.1 as f32, 1.0 / w, 1.0 / h];
        let view_desc = D3D11_SHADER_RESOURCE_VIEW_DESC {
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            ViewDimension: D3D11_SRV_DIMENSION_TEXTURE2D,
            Anonymous: D3D11_SHADER_RESOURCE_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_SRV { MostDetailedMip: 0, MipLevels: 1 } },
        };
        let mut view = None;
        unsafe {
            device.CreateShaderResourceView(source, Some(&view_desc), Some(&mut view))?;
            context.UpdateSubresource(&self.constants, 0, None, constants.as_ptr().cast(), 0, 0);
            context.IASetInputLayout(None);
            context.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            context.VSSetShader(&self.vs, None);
            context.PSSetShaderResources(0, Some(&[view]));
            context.PSSetSamplers(0, Some(&[Some(self.sampler.clone())]));
            context.PSSetConstantBuffers(0, Some(&[Some(self.constants.clone())]));
        }
        for (i, (ps, format)) in self.ps.iter().enumerate() {
            // NV12's chroma: half the size each way.
            let (vw, vh) = if i == 0 { to } else { (to.0 / 2, to.1 / 2) };
            let rtv_desc = D3D11_RENDER_TARGET_VIEW_DESC {
                Format: *format,
                ViewDimension: D3D11_RTV_DIMENSION_TEXTURE2D,
                Anonymous: D3D11_RENDER_TARGET_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_RTV { MipSlice: 0 } },
            };
            let mut out = None;
            unsafe {
                device.CreateRenderTargetView(target, Some(&rtv_desc), Some(&mut out))?;
                let viewport = D3D11_VIEWPORT { TopLeftX: 0.0, TopLeftY: 0.0, Width: vw as f32, Height: vh as f32, MinDepth: 0.0, MaxDepth: 1.0 };
                context.OMSetRenderTargets(Some(&[out]), None);
                context.RSSetViewports(Some(&[viewport]));
                context.PSSetShader(ps, None);
                context.Draw(3, 0);
            }
        }
        unsafe {
            // Nothing left bound: the picture can be written again, the target read by the encoder.
            context.PSSetShaderResources(0, Some(&[None]));
            context.OMSetRenderTargets(None, None);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::super::capture::{Gpu, Scaler};
    use windows::Win32::Graphics::Direct3D11::*;
    use windows::Win32::Graphics::Dxgi::Common::*;

    /// A BGRA picture of `width`×`height`, each pixel `colour(x, y)` ([r, g, b]), as the capture's copy is made.
    fn picture(gpu: &Gpu, width: u32, height: u32, colour: impl Fn(u32, u32) -> [u8; 3]) -> ID3D11Texture2D {
        let mut pixels = Vec::with_capacity((width * height * 4) as usize);
        for y in 0..height {
            for x in 0..width {
                let [r, g, b] = colour(x, y);
                pixels.extend_from_slice(&[b, g, r, 255]);
            }
        }
        let desc = D3D11_TEXTURE2D_DESC {
            Width: width,
            Height: height,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: (D3D11_BIND_RENDER_TARGET.0 | D3D11_BIND_SHADER_RESOURCE.0) as u32,
            CPUAccessFlags: 0,
            MiscFlags: 0,
        };
        let data = D3D11_SUBRESOURCE_DATA { pSysMem: pixels.as_ptr().cast(), SysMemPitch: width * 4, SysMemSlicePitch: 0 };
        let mut texture = None;
        unsafe { gpu.device.CreateTexture2D(&desc, Some(&data), Some(&mut texture)).unwrap() };
        texture.unwrap()
    }

    fn y(c: [u8; 3]) -> f32 {
        16.0 + (0.2126 * c[0] as f32 + 0.7152 * c[1] as f32 + 0.0722 * c[2] as f32) * 219.0 / 255.0
    }

    fn uv(c: [u8; 3]) -> [f32; 2] {
        let [r, g, b] = c.map(|v| v as f32);
        [128.0 + (-0.1146 * r - 0.3854 * g + 0.5 * b) * 224.0 / 255.0, 128.0 + (0.5 * r - 0.4542 * g - 0.0458 * b) * 224.0 / 255.0]
    }

    /// Without a video processor: a picture of four coloured quarters, halved, as NV12 and as BGRA; a part of it (one
    /// quarter) framed alone. Each output pixel inside a quarter (not at its edges, where the taps mix two) its colour.
    #[test]
    fn scaled_by_shaders_without_a_video_processor() {
        let gpu = Gpu::warp();
        let quarters = [[255u8, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 255]];
        let (w, h) = (64u32, 32u32);
        let source = picture(&gpu, w, h, |x, y| quarters[(x >= w / 2) as usize + 2 * (y >= h / 2) as usize]);
        let (tw, th) = (32u32, 16u32);
        let quarter = |x: u32, y: u32| quarters[(x >= tw / 2) as usize + 2 * (y >= th / 2) as usize];
        let inside = |x: u32, y: u32| x % (tw / 2) > 1 && x % (tw / 2) < tw / 2 - 2 && y % (th / 2) > 1 && y % (th / 2) < th / 2 - 2;

        let mut scaler = Scaler::new(&gpu, (w, h), (tw, th), DXGI_FORMAT_NV12).unwrap();
        let out = scaler.run(&gpu, &source, (0, 0, w, h)).unwrap();
        let (bytes, pitch) = gpu.read(&out, &mut None).unwrap();
        for py in 0..th {
            for px in 0..tw {
                if !inside(px, py) {
                    continue;
                }
                let c = quarter(px, py);
                let got = bytes[py as usize * pitch + px as usize] as f32;
                assert!((got - y(c)).abs() <= 1.5, "Y at {px},{py}: {got}, not {}", y(c));
                if px % 2 == 0 && py % 2 == 0 && inside(px + 1, py + 1) {
                    let at = (th as usize + py as usize / 2) * pitch + px as usize;
                    let want = uv(c);
                    for i in 0..2 {
                        let got = bytes[at + i] as f32;
                        assert!((got - want[i]).abs() <= 1.5, "UV at {px},{py}: {got}, not {}", want[i]);
                    }
                }
            }
        }

        // One quarter (the blue one, bottom left) framed alone, as BGRA.
        let mut scaler = Scaler::new(&gpu, (w, h), (tw, th), DXGI_FORMAT_B8G8R8A8_UNORM).unwrap();
        let out = scaler.run(&gpu, &source, (0, h / 2, w / 2, h / 2)).unwrap();
        let (bytes, pitch) = gpu.read(&out, &mut None).unwrap();
        for py in 0..th {
            for px in 0..tw {
                let at = py as usize * pitch + px as usize * 4;
                assert_eq!(&bytes[at..at + 4], &[255, 0, 0, 255], "at {px},{py}");
            }
        }
    }
}
