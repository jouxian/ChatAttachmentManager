package main

import (
	"flag"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
)

type point struct{ x, y float64 }

func roundedRect(p point, left, top, right, bottom, radius float64) bool {
	cx := math.Max(left+radius, math.Min(p.x, right-radius))
	cy := math.Max(top+radius, math.Min(p.y, bottom-radius))
	dx, dy := p.x-cx, p.y-cy
	return dx*dx+dy*dy <= radius*radius
}

func inTriangle(p, a, b, c point) bool {
	cross := func(p1, p2, p3 point) float64 {
		return (p1.x-p3.x)*(p2.y-p3.y) - (p2.x-p3.x)*(p1.y-p3.y)
	}
	d1, d2, d3 := cross(p, a, b), cross(p, b, c), cross(p, c, a)
	return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
}

func cubic(a, b, c, d point, t float64) point {
	u := 1 - t
	return point{
		x: u*u*u*a.x + 3*u*u*t*b.x + 3*u*t*t*c.x + t*t*t*d.x,
		y: u*u*u*a.y + 3*u*u*t*b.y + 3*u*t*t*c.y + t*t*t*d.y,
	}
}

func paperclipPath() []point {
	path := []point{{x: 294, y: 166}}
	appendCurve := func(b, c, d point) {
		a := path[len(path)-1]
		for i := 1; i <= 24; i++ {
			path = append(path, cubic(a, b, c, d, float64(i)/24))
		}
	}
	appendCurve(point{334, 165}, point{354, 183}, point{354, 211})
	appendCurve(point{354, 246}, point{354, 280}, point{354, 313})
	appendCurve(point{354, 360}, point{267, 360}, point{267, 313})
	appendCurve(point{267, 282}, point{267, 251}, point{267, 221})
	appendCurve(point{267, 190}, point{309, 190}, point{309, 221})
	appendCurve(point{309, 246}, point{309, 274}, point{309, 299})
	return path
}

func segmentDistance(p, a, b point) float64 {
	dx, dy := b.x-a.x, b.y-a.y
	if dx == 0 && dy == 0 {
		return math.Hypot(p.x-a.x, p.y-a.y)
	}
	t := ((p.x-a.x)*dx + (p.y-a.y)*dy) / (dx*dx + dy*dy)
	t = math.Max(0, math.Min(1, t))
	return math.Hypot(p.x-(a.x+t*dx), p.y-(a.y+t*dy))
}

func pathDistance(p point, path []point) float64 {
	best := math.MaxFloat64
	for i := 1; i < len(path); i++ {
		best = math.Min(best, segmentDistance(p, path[i-1], path[i]))
	}
	return best
}

func backgroundColor(p point) color.RGBA {
	if !roundedRect(p, 20, 20, 492, 492, 104) {
		return color.RGBA{}
	}
	t := math.Max(0, math.Min(1, (p.x+p.y-40)/904))
	return color.RGBA{R: uint8(13 + 9*t), G: uint8(28 + 31*t), B: uint8(54 + 47*t), A: 255}
}

func foregroundColor(p point, clip []point) color.RGBA {
	if math.Hypot(p.x-385, p.y-119) < 20 {
		return color.RGBA{R: 89, G: 240, B: 178, A: 255}
	}
	if math.Hypot(p.x-385, p.y-119) < 27 {
		return color.RGBA{R: 10, G: 22, B: 42, A: 255}
	}
	if p.x >= 245 && p.x <= 375 && p.y >= 155 && p.y <= 370 && pathDistance(p, clip) < 14 {
		return color.RGBA{R: 242, G: 250, B: 255, A: 255}
	}
	for _, dot := range []point{{142, 286}, {178, 286}, {214, 286}} {
		if math.Hypot(p.x-dot.x, p.y-dot.y) < 8 {
			return color.RGBA{R: 226, G: 255, B: 250, A: 230}
		}
	}
	bubble := roundedRect(p, 72, 92, 436, 384, 76) || inTriangle(p, point{145, 347}, point{102, 423}, point{220, 378})
	if bubble {
		t := math.Max(0, math.Min(1, (p.x+p.y-164)/584))
		return color.RGBA{R: uint8(48 - 20*t), G: uint8(225 - 78*t), B: uint8(198 + 48*t), A: 255}
	}
	return color.RGBA{}
}

func composite(background, foreground color.RGBA) color.RGBA {
	if foreground.A == 0 {
		return background
	}
	a := uint32(foreground.A)
	inv := uint32(255) - a
	return color.RGBA{
		R: uint8((uint32(foreground.R)*a + uint32(background.R)*inv) / 255),
		G: uint8((uint32(foreground.G)*a + uint32(background.G)*inv) / 255),
		B: uint8((uint32(foreground.B)*a + uint32(background.B)*inv) / 255),
		A: uint8(a + (uint32(background.A)*inv)/255),
	}
}

func render(size int) *image.RGBA {
	const samples = 4
	img := image.NewRGBA(image.Rect(0, 0, size, size))
	clip := paperclipPath()
	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			var r, g, b, a uint32
			for sy := 0; sy < samples; sy++ {
				for sx := 0; sx < samples; sx++ {
					p := point{x: float64(x) + (float64(sx)+0.5)/samples, y: float64(y) + (float64(sy)+0.5)/samples}
					c := composite(backgroundColor(p), foregroundColor(p, clip))
					r += uint32(c.R)
					g += uint32(c.G)
					b += uint32(c.B)
					a += uint32(c.A)
				}
			}
			count := uint32(samples * samples)
			img.SetRGBA(x, y, color.RGBA{R: uint8(r / count), G: uint8(g / count), B: uint8(b / count), A: uint8(a / count)})
		}
	}
	return img
}

func main() {
	out := flag.String("out", "Launcher/winres/ChatAttachmentManager.png", "output PNG path")
	flag.Parse()
	file, err := os.Create(*out)
	if err != nil {
		panic(err)
	}
	defer file.Close()
	if err := png.Encode(file, render(512)); err != nil {
		panic(err)
	}
}
