#include "font_renderer.h"

#include "agg_lcd_distribution_lut.h"
#include "agg_pixfmt_rgb.h"
#include "agg_pixfmt_rgba.h"
#include "agg_gamma_lut.h"

#include "font_renderer_alpha.h"

typedef agg::blender_rgb_gamma<agg::rgba8, agg::order_bgra, agg::gamma_lut<> > blender_gamma_type;

class FontRendererImpl {
public:
    // Conventional LUT values: (1./3., 2./9., 1./9.)
    // The values below are fine tuned as in the Elementary Plot library.

    FontRendererImpl(bool hinting, bool kerning, float gamma_value) :
        m_renderer(hinting, kerning),
        m_gamma_lut(double(gamma_value)),
        m_blender(),
        m_lcd_lut(0.448, 0.184, 0.092)
    {
        m_blender.gamma(m_gamma_lut);
    }

    font_renderer_alpha& renderer_alpha() { return m_renderer; }
    blender_gamma_type& blender() { return m_blender; }
    agg::gamma_lut<>& gamma() { return m_gamma_lut; }
    agg::lcd_distribution_lut& lcd_distribution_lut() { return m_lcd_lut; }

private:
    font_renderer_alpha m_renderer;
    agg::gamma_lut<> m_gamma_lut;
    blender_gamma_type m_blender;
    agg::lcd_distribution_lut m_lcd_lut;
};

FontRenderer *FontRendererNew(unsigned int flags, float gamma) {
    bool hinting = ((flags & FONT_RENDERER_HINTING) != 0);
    bool kerning = ((flags & FONT_RENDERER_KERNING) != 0);
    return new FontRendererImpl(hinting, kerning, gamma);
}

void FontRendererFree(FontRenderer *font_renderer) {
    delete font_renderer;    
}

int FontRendererLoadFont(FontRenderer *font_renderer, const char *filename) {
    bool success = font_renderer->renderer_alpha().load_font(filename);
    return (success ? 0 : 1);
}

int FontRendererGetFontHeight(FontRenderer *font_renderer, float size) {
    font_renderer_alpha& renderer_alpha = font_renderer->renderer_alpha();
    double ascender, descender;
    renderer_alpha.get_font_vmetrics(ascender, descender);
    int face_height = renderer_alpha.get_face_height();
    float scale = renderer_alpha.scale_for_em_to_pixels(size);
    return int((ascender - descender) * face_height * scale + 0.5);
}

static void glyph_trim_rect(agg::rendering_buffer& ren_buf, GlyphBitmapInfo *gli, int subpixel_scale) {
    const int height = ren_buf.height();
    int x0 = gli->x0 * subpixel_scale, x1 = gli->x1 * subpixel_scale;
    int y0 = gli->y0, y1 = gli->y1;
    for (int y = gli->y0; y < gli->y1; y++) {
        uint8_t *row = ren_buf.row_ptr(height - 1 - y);
        unsigned int row_bitsum = 0;
        for (int x = x0; x < x1; x++) {
            row_bitsum |= row[x];
        }
        if (row_bitsum == 0) {
            y0++;
        } else {
            break;
        }
    }
    for (int y = gli->y1 - 1; y >= gli->y0; y--) {
        uint8_t *row = ren_buf.row_ptr(height - 1 - y);
        unsigned int row_bitsum = 0;
        for (int x = x0; x < x1; x++) {
            row_bitsum |= row[x];
        }
        if (row_bitsum == 0) {
            y1--;
        } else {
            break;
        }
    }
    int xtriml = x0, xtrimr = x1;
    for (int y = y0; y < y1; y++) {
        uint8_t *row = ren_buf.row_ptr(height - 1 - y);
        for (int x = x0; x < x1; x += subpixel_scale) {
            unsigned int xaccu = 0;
            for (int i = 0; i < subpixel_scale; i++) {
                xaccu |= row[x + i];
            }
            if (xaccu > 0) {
                // FIXME: fix xs comparaison below.
                if (x < xtriml) xtriml = x;
                break;
            }
        }
        for (int x = x1 - subpixel_scale; x >= x0; x -= subpixel_scale) {
            unsigned int xaccu = 0;
            for (int i = 0; i < subpixel_scale; i++) {
                xaccu |= row[x + i];
            }
            if (xaccu > 0) {
                if (x > xtrimr) xtrimr = x + 1;
                break;
            }
        }
    }
    gli->xoff += (xtriml - x0) / subpixel_scale;
    gli->yoff += (y0 - gli->y0);
    gli->x0 = xtriml / subpixel_scale;
    gli->y0 = y0;
    gli->x1 = xtrimr / subpixel_scale;
    gli->y1 = y1;
}

static int ceil_to_multiple(int n, int p) {
    return p * ((n + p - 1) / p);
}

int FontRendererBakeFontBitmap(FontRenderer *font_renderer, int font_height,
    void *pixels, int pixels_width, int pixels_height,
    int first_char, int num_chars, GlyphBitmapInfo *glyphs, int subpixel_scale)
{
    font_renderer_alpha& renderer_alpha = font_renderer->renderer_alpha();

    const int pixel_size = 1;
    memset(pixels, 0x00, pixels_width * pixels_height * subpixel_scale * pixel_size);

    double ascender, descender;
    renderer_alpha.get_font_vmetrics(ascender, descender);

    const int ascender_px  = int(ascender  * font_height + 0.5);
    const int descender_px = int(descender * font_height + 0.5);

    const int pad_y = font_height / 10;
    const int y_step = font_height + 2 * pad_y;

    agg::rendering_buffer ren_buf((agg::int8u *) pixels, pixels_width * subpixel_scale, pixels_height, -pixels_width * subpixel_scale * pixel_size);
    const int x_start = subpixel_scale;
    int x = x_start, y = pixels_height;
    int res = 0;
    const agg::alpha8 text_color(0xff);
#ifdef FONT_RENDERER_HEIGHT_HACK
    const int font_height_reduced = (font_height * 86) / 100;
#else
    const int font_height_reduced = font_height;
#endif
    for (int i = 0; i < num_chars; i++) {
        int codepoint = first_char + i;
        if (x + font_height * subpixel_scale > pixels_width * subpixel_scale) {
            x = x_start;
            y -= y_step;
        }
        if (y - font_height - 2 * pad_y < 0) {
            res = -1;
            break;
        }
        const int y_baseline = y - pad_y - font_height;

        double x_next = x, y_next = y_baseline;
        renderer_alpha.render_codepoint(ren_buf, font_height_reduced, text_color, x_next, y_next, codepoint, subpixel_scale);
        int x_next_i = (subpixel_scale == 1 ? int(x_next + 1.0) : ceil_to_multiple(x_next + 0.5, subpixel_scale));

        GlyphBitmapInfo& glyph_info = glyphs[i];
        glyph_info.x0 = x / subpixel_scale;
        glyph_info.y0 = pixels_height - (y_baseline + ascender_px  + pad_y);
        glyph_info.x1 = x_next_i / subpixel_scale;
        glyph_info.y1 = pixels_height - (y_baseline + descender_px - pad_y);

        glyph_info.xoff = 0;
        glyph_info.yoff = -pad_y;
        glyph_info.xadvance = (x_next - x) / subpixel_scale;

        glyph_trim_rect(ren_buf, &glyph_info, subpixel_scale);

        x = x_next_i;

#ifdef FONT_RENDERER_DEBUG
        fprintf(stderr,
          "glyph codepoint %3d (ascii: %1c), BOX (%3d, %3d) (%3d, %3d), "
          "OFFSET (%.5g, %.5g), X ADVANCE %.5g\n",
          codepoint, i,
          glyph_info.x0, glyph_info.y0, glyph_info.x1, glyph_info.y1,
          glyph_info.xoff, glyph_info.yoff, glyph_info.xadvance);
#endif
    }
    return res;
}

// FIXME: remove the Blender template argument.
template <typename Blender>
void blend_solid_hspan(agg::rendering_buffer& rbuf, Blender& blender,
                        int x, int y, unsigned len,
                        const typename Blender::color_type& c, const agg::int8u* covers)
{
    typedef Blender  blender_type;
    typedef typename blender_type::color_type color_type;
    typedef typename blender_type::order_type order_type;
    typedef typename color_type::value_type value_type;
    typedef typename color_type::calc_type calc_type;

    if (c.a)
    {
        value_type* p = (value_type*)rbuf.row_ptr(x, y, len) + (x << 2);
        do 
        {
            calc_type alpha = (calc_type(c.a) * (calc_type(*covers) + 1)) >> 8;
            if(alpha == color_type::base_mask)
            {
                p[order_type::R] = c.r;
                p[order_type::G] = c.g;
                p[order_type::B] = c.b;
            }
            else
            {
                blender.blend_pix(p, c.r, c.g, c.b, alpha, *covers);
            }
            p += 4;
            ++covers;
        }
        while(--len);
    }
}

static int floor_div(int a, int b) {
    int rem = a % b;
    if (rem < 0) {
        rem += b;
    }
    return (a - rem) / b;
}

void blend_solid_hspan_rgb_subpixel(agg::rendering_buffer& rbuf, agg::gamma_lut<>& gamma, agg::lcd_distribution_lut& lcd_lut,
    int x_lcd, int y, unsigned len,
    const agg::rgba8& c,
    const agg::int8u* covers)
{
    // const int subpixel_scale = 3;
    // FIXME: rowlen à verifier
    // unsigned rowlen = rbuf.width() * subpixel_scale;
    // FIXME: no correct boundary limits for cx and cx_max
    // int cx = (x_lcd - 2 >= 0 ? -2 : -x_lcd);
    // int cx_max = (len + 2 <= rowlen ? len + 1 : rowlen - 1);
    const int pixel_size = 4;
    int cx = -2;
    int cx_max = len + 1;

    const int x_min = floor_div(x_lcd + cx, 3);
    const int x_max = floor_div(x_lcd + cx_max, 3);

    const agg::int8u rgb[3] = { c.r, c.g, c.b };
    agg::int8u* p = rbuf.row_ptr(y) + x_min * pixel_size;

    // Indexes to adress RGB colors in a BGRA32 format.
    const int pixel_index[3] = {2, 1, 0};
    for (int x = x_min; x <= x_max; x++)
    {
        for (int i = 0; i < 3; i++) {
            int new_cx = x * 3 - x_lcd + i;
            unsigned c_conv = lcd_lut.convolution(covers, new_cx, 0, len - 1);
            unsigned alpha = (c_conv + 1) * (c.a + 1);
            unsigned dst_col = gamma.dir(rgb[i]);
            unsigned src_col = gamma.dir(*(p + pixel_index[i]));
            *(p + pixel_index[i]) = gamma.inv((((dst_col - src_col) * alpha) + (src_col << 16)) >> 16);
        }
        //p[3] = 0xff;
        p += 4;
    }
}

// destination implicitly BGRA32. Source implictly single-byte renderer_alpha coverage.
void FontRendererBlendGamma(FontRenderer *font_renderer, uint8_t *dst, int dst_stride, uint8_t *src, int src_stride, int region_width, int region_height, FontRendererColor color) {
    blender_gamma_type& blender = font_renderer->blender();
    agg::rendering_buffer dst_ren_buf(dst, region_width, region_height, dst_stride);
    const agg::rgba8 color_a(color.r, color.g, color.b);
    for (int x = 0, y = 0; y < region_height; y++) {
        agg::int8u *covers = src + y * src_stride;
        blend_solid_hspan<blender_gamma_type>(dst_ren_buf, blender, x, y, region_width, color_a, covers);
    }
}

// destination implicitly BGRA32. Source implictly single-byte renderer_alpha coverage.
void FontRendererBlendGammaSubpixel(FontRenderer *font_renderer, uint8_t *dst, int dst_stride, uint8_t *src, int src_stride, int region_width, int region_height, FontRendererColor color) {
    const int subpixel_scale = 3;
    agg::gamma_lut<>& gamma = font_renderer->gamma();
    agg::lcd_distribution_lut& lcd_lut = font_renderer->lcd_distribution_lut();
    agg::rendering_buffer dst_ren_buf(dst, region_width, region_height, dst_stride);
    const agg::rgba8 color_a(color.r, color.g, color.b);
    for (int x = 0, y = 0; y < region_height; y++) {
        agg::int8u *covers = src + y * src_stride;
        blend_solid_hspan_rgb_subpixel(dst_ren_buf, gamma, lcd_lut, x, y, region_width * subpixel_scale, color_a, covers);
    }
}