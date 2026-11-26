from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
out = Path(__file__).resolve().parents[1] / "build" / "DockShot.iconset"
out.mkdir(parents=True, exist_ok=True)
s = 1024
mask = Image.new("L",(s,s))
ImageDraw.Draw(mask).rounded_rectangle((90,78,934,922),radius=190,fill=255)
shade = Image.new("RGBA",(s,s))
shadow = Image.new("L",(s,s))
ImageDraw.Draw(shadow).rounded_rectangle((100,96,924,944),radius=185,fill=120)
shade.putalpha(shadow.filter(ImageFilter.GaussianBlur(15)))
tile = Image.new("RGB",(s,s))
pixels = tile.load()
for y in range(78,923):
    for x in range(90,935):
        t = min(1,max(0,(.34*(x-90)+.66*(y-78))/844))
        glint = max(0,1-((x-240)/490)**2-((y-135)/370)**2)*.13
        rgb = tuple(round((a+(b-a)*t)*(1-glint)+255*glint) for a,b in zip((100,191,255),(43,75,200)))
        pixels[x,y]=rgb
shade.paste(tile,(0,0),mask)
draw = ImageDraw.Draw(shade)
draw.rounded_rectangle((91,79,933,920),radius=190,outline=(177,216,255,255),width=3)
# Four rounded viewfinder brackets and a shutter point form the Dock icon.
corn = Image.new("RGBA",(s,s))
d = ImageDraw.Draw(corn)
ink = (250,253,255,255)
d.rounded_rectangle((250,245,419,303),radius=28,fill=ink)
d.rounded_rectangle((250,245,308,414),radius=28,fill=ink)
for placement in (corn,corn.transpose(Image.Transpose.FLIP_LEFT_RIGHT),
                  corn.transpose(Image.Transpose.FLIP_TOP_BOTTOM),corn.transpose(Image.Transpose.ROTATE_180)):
    shade.alpha_composite(placement)
draw.ellipse((451,451,573,573),fill=ink)
for base in (16,32,128,256,512):
    for scale,suffix in ((1,""),(2,"@2x")):
        dim = base*scale
        shade.resize((dim,dim),Image.Resampling.LANCZOS).save(out / f"icon_{base}x{base}{suffix}.png")
