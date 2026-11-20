#!/usr/bin/env python3
"""生成原创零食配置与 120×120 俯视包装 SVG。

只复用品类通用的包装结构，不使用真实品牌、商标、IP 角色或专有包装图案。
包装文字通过 fontTools 转为矢量路径，避免 Godot SVG 导入忽略 <text>。
运行：python3 -I tools/make_snacks.py（需 fontTools）
"""
from pathlib import Path
import json

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parents[1]
SVG_DIR = ROOT / "assets" / "svg"
DATA_PATH = ROOT / "data" / "snacks.json"
FONT = TTFont(str(ROOT / "assets" / "fonts" / "ui_font.ttc"), fontNumber=0)
GLYPHS = FONT.getGlyphSet()
CMAP = FONT.getBestCmap()
METRICS = FONT["hmtx"].metrics
UNITS_PER_EM = FONT["head"].unitsPerEm

CATEGORIES = [
    ("puffed", "膨化食品", "枕式充氮袋、锯齿封口与分享装结构"),
    ("sweets", "糖果巧克力", "扭结糖纸、排块套封与小盒便携装"),
    ("bakery", "饼干糕点", "纸盒、铁盒、透明窗与烘焙牛皮纸配色"),
    ("jelly_pudding", "果冻布丁", "圆形撕膜杯、宽杯沿与水果口味标签"),
    ("nuts", "坚果炒货", "自立拉链袋、密封窗口与坚果原产地色系"),
    ("savory", "辣味卤味", "真空自立袋、深色酱卤标签与红色口味标识"),
    ("dried_fruit", "果干蜜饯", "防潮拉链袋、果实插画与自然果色"),
    ("drinks", "饮料乳品", "瓶装饮料、屋顶纸盒与圆杯酸奶包装"),
]

# id, category, name, brand, mark, pack, weight, product_scale, color, accent, package_note
# product_scale 是人工标定的现实包装相对尺寸；两轴等比使用，与重量和全局包装倍率无关。
PRODUCTS = [
    ("chips", "puffed", "脆脆锅巴", "禾谷", "锅", "pillow", 40, 1.05, "#C8A06A", "#C94F3D", "牛皮纸色枕式袋，双端锯齿封口"),
    ("crisps", "puffed", "原切薯片", "禾谷", "薯", "pillow", 35, 1.08, "#E8C97A", "#7A9B76", "浅金充氮袋，绿色原切口味标"),
    ("corn_curls", "puffed", "黄金玉米卷", "禾谷", "玉", "pillow", 32, 1.00, "#E3A93C", "#C94F3D", "橙黄枕式袋，红色玉米口味标"),
    ("prawn_sticks", "puffed", "鲜虾脆条", "禾谷", "虾", "pillow", 30, 0.95, "#E88B72", "#F5E6C8", "珊瑚色细长充氮袋，奶油色标签"),
    ("yam_crisps", "puffed", "山药薄脆", "禾谷", "药", "pillow", 28, 0.92, "#A8B47A", "#F5E6C8", "豆绿色薄脆袋，浅色清爽标签"),
    ("candy", "sweets", "水果硬糖", "糖屿", "糖", "twist", 12, 0.55, "#3E5C8F", "#E8963E", "蓝橙双色扭结糖纸"),
    ("chocolate", "sweets", "黑巧方砖", "糖屿", "巧", "bar", 50, 0.78, "#6B4436", "#C94F3D", "深棕排块与红色纸质套封"),
    ("gummy", "sweets", "果汁软糖", "糖屿", "软", "pouch", 25, 0.72, "#9B7BC8", "#E8C97A", "紫色小自立袋与透明糖果窗"),
    ("nougat", "sweets", "花生牛轧糖", "糖屿", "轧", "twist", 18, 0.58, "#F0D9B5", "#C94F3D", "米白红纹扭结独立糖纸"),
    ("mints", "sweets", "清凉薄荷糖", "糖屿", "凉", "box", 15, 0.65, "#74B8B0", "#F5F0E4", "青绿色翻盖小纸盒"),
    ("biscuit", "bakery", "铁盒饼干", "麦丘", "饼", "tin", 80, 1.08, "#C94F3D", "#E8C97A", "红色金属盒与金色圆形纸贴"),
    ("soda_cracker", "bakery", "香葱苏打饼", "麦丘", "苏", "box", 55, 0.95, "#7A9B76", "#F5E6C8", "绿色长形纸盒与香葱口味标"),
    ("egg_roll", "bakery", "黄油蛋卷", "麦丘", "卷", "tin", 45, 1.02, "#D7A84D", "#C94F3D", "金黄铁盒与红色烘焙标签"),
    ("waffle", "bakery", "格子华夫", "麦丘", "华", "pillow", 60, 0.88, "#D99B56", "#F5E6C8", "暖棕枕式袋与奶油色标签"),
    ("yolk_cake", "bakery", "金沙蛋黄酥", "麦丘", "酥", "box", 55, 0.82, "#B85B44", "#E8C97A", "陶红天地盖纸盒与金色贴纸"),
    ("jelly", "jelly_pudding", "橘子果冻杯", "咕岛", "冻", "cup", 60, 0.78, "#E8963E", "#F5E6C8", "橙色撕膜圆杯与宽杯沿"),
    ("lychee_jelly", "jelly_pudding", "荔枝果冻", "咕岛", "荔", "cup", 55, 0.75, "#E9A6A0", "#F5F0E4", "粉白果冻杯与荔枝口味环标"),
    ("mango_pudding", "jelly_pudding", "芒果布丁", "咕岛", "芒", "cup", 70, 0.82, "#F0C44F", "#FFF2C2", "黄色布丁杯与浅黄撕膜盖"),
    ("coconut_cup", "jelly_pudding", "椰果奶冻", "咕岛", "椰", "cup", 65, 0.80, "#8DC5B5", "#F5F0E4", "青白奶冻杯与椰果口味标"),
    ("grass_jelly", "jelly_pudding", "仙草冻", "咕岛", "仙", "cup", 80, 0.85, "#59604C", "#D9C89C", "深绿色仙草杯与米色封膜"),
    ("mixed_nuts", "nuts", "每日坚果", "山里集", "坚", "pouch", 30, 0.82, "#7A9B76", "#E8C97A", "绿色每日装拉链袋与混合坚果窗"),
    ("cashew", "nuts", "盐焗腰果", "山里集", "腰", "pouch", 35, 0.86, "#D7B47A", "#7A9B76", "米金自立袋与绿色盐焗标"),
    ("walnut", "nuts", "琥珀核桃", "山里集", "核", "pouch", 40, 0.88, "#A66A43", "#E8C97A", "胡桃棕拉链袋与金色标签"),
    ("pistachio", "nuts", "原味开心果", "山里集", "开", "pouch", 38, 0.86, "#9BB77D", "#F5E6C8", "浅绿自立袋与奶油色标签"),
    ("sunflower_seeds", "nuts", "香葵瓜子", "山里集", "瓜", "pillow", 45, 0.98, "#6D7356", "#E8C97A", "灰绿枕式袋与金色炒货标"),
    ("latiao", "savory", "香辣面筋", "卤巷", "辣", "pillow", 30, 0.92, "#C94F3D", "#E8C97A", "红色枕式袋与金色辣味标"),
    ("pork_jerky", "savory", "蜜汁肉脯", "卤巷", "脯", "pouch", 45, 0.90, "#9E4F3D", "#E8C97A", "红棕真空自立袋与蜜汁标签"),
    ("duck_neck", "savory", "酱香鸭脖", "卤巷", "鸭", "pouch", 60, 0.95, "#6F4B3A", "#C94F3D", "深卤色真空袋与红色酱香标"),
    ("fish_tofu", "savory", "鱼豆腐", "卤巷", "鱼", "pouch", 40, 0.80, "#E5A35C", "#C94F3D", "橙金小袋与红色香辣口味标"),
    ("konjac", "savory", "素毛肚", "卤巷", "肚", "pouch", 35, 0.82, "#B64C3E", "#F5E6C8", "砖红真空袋与浅色素食标签"),
    ("mango_dry", "dried_fruit", "芒果干", "果堂", "芒", "pouch", 42, 0.88, "#E9B641", "#F5E6C8", "金黄防潮袋与浅色水果标签"),
    ("strawberry_dry", "dried_fruit", "草莓干", "果堂", "莓", "pouch", 30, 0.80, "#D86967", "#F5E6C8", "莓红拉链袋与奶油色标签"),
    ("raisin", "dried_fruit", "新疆葡萄干", "果堂", "葡", "pouch", 35, 0.78, "#7B5B7E", "#E8C97A", "紫棕防潮袋与金色果干标"),
    ("preserved_plum", "dried_fruit", "九制话梅", "果堂", "梅", "pouch", 28, 0.76, "#8A5D50", "#E8C97A", "梅棕自立袋与金色蜜饯标"),
    ("hawthorn", "dried_fruit", "山楂条", "果堂", "楂", "pillow", 32, 0.84, "#B94F4B", "#F5E6C8", "山楂红枕式袋与浅色标签"),
    ("soda", "drinks", "橘子汽水", "晴禾", "汽", "bottle", 250, 1.15, "#5E7D5B", "#E8963E", "绿色瓶身与橙色汽水标签"),
    ("milk", "drinks", "甜牛奶", "晴禾", "奶", "carton", 200, 1.08, "#F5F0E4", "#3E5C8F", "蓝白屋顶纸盒与折角封顶"),
    ("yogurt", "drinks", "原味酸奶", "晴禾", "酸", "cup", 180, 0.88, "#E9E2CC", "#7A9B76", "米白圆杯与绿色乳品环标"),
    ("lemon_tea", "drinks", "冻柠茶", "晴禾", "柠", "bottle", 250, 1.15, "#C59B45", "#F5E6C8", "茶金瓶身与浅色柠檬标签"),
    ("soy_milk", "drinks", "醇香豆奶", "晴禾", "豆", "carton", 250, 1.10, "#E7D9B8", "#7A9B76", "米绿屋顶纸盒与豆奶标签"),
]


def label_ink(color):
    """浅色包装在奶油色标签上改用深棕字，避免小尺寸标记失去对比度。"""
    r, g, b = (int(color[i:i + 2], 16) / 255.0 for i in (1, 3, 5))
    luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return "#4A3525" if luminance > 0.45 else color


def text(x, y, value, size, fill, weight=700):
    """把文字轮廓直接写入 SVG；Godot/ThorVG 不依赖系统字体即可显示。"""
    del weight  # 字重由项目字体本身决定，保留参数以维持包装模板调用形式。
    scale = size / UNITS_PER_EM
    glyphs = [(ch, CMAP.get(ord(ch), ".notdef")) for ch in value]
    total_width = sum(METRICS[name][0] for _ch, name in glyphs)
    cursor = -total_width * 0.5
    paths = []
    for ch, name in glyphs:
        pen = SVGPathPen(GLYPHS)
        GLYPHS[name].draw(pen)
        paths.append(
            f'<path d="{pen.getCommands()}" transform="translate({x} {y}) '
            f'scale({scale:.6f} {-scale:.6f}) translate({cursor:.2f} 0)"/>'
        )
        cursor += METRICS[name][0]
    return f'<g fill="{fill}" stroke="none">' + "".join(paths) + '</g>'


def motif(category, accent):
    """品类通用食物图形，不对应任何真实商品包装图案。"""
    if category in ("puffed", "bakery"):
        return (f'<g fill="{accent}" stroke="#4A3525" stroke-width="1.4">'
                '<ellipse cx="47" cy="82" rx="10" ry="5" transform="rotate(-18 47 82)"/>'
                '<ellipse cx="63" cy="86" rx="11" ry="5" transform="rotate(12 63 86)"/>'
                '<ellipse cx="76" cy="78" rx="9" ry="5" transform="rotate(-24 76 78)"/></g>')
    if category in ("nuts", "dried_fruit"):
        return (f'<g fill="{accent}" stroke="#4A3525" stroke-width="1.3">'
                '<ellipse cx="46" cy="83" rx="8" ry="5" transform="rotate(28 46 83)"/>'
                '<ellipse cx="61" cy="86" rx="8" ry="5" transform="rotate(-18 61 86)"/>'
                '<ellipse cx="75" cy="80" rx="7" ry="5" transform="rotate(35 75 80)"/></g>')
    if category == "savory":
        return (f'<g fill="{accent}" stroke="#4A3525" stroke-width="1.2">'
                '<path d="M39 82 l15 -7 l4 7 l-15 7 z"/><path d="M56 88 l16 -8 l4 7 l-16 7 z"/>'
                '<path d="M70 76 l13 -5 l3 6 l-13 5 z"/></g>')
    return (f'<g fill="{accent}" stroke="#4A3525" stroke-width="1.2">'
            '<circle cx="47" cy="82" r="7"/><circle cx="62" cy="86" r="8"/><circle cx="76" cy="78" r="6"/>'
            '<path d="M59 73 q7 -8 14 -2" fill="none"/></g>')


def render(p):
    color, accent, category = p["color"], p["accent"], p["category"]
    brand, mark, pack = p["brand"], p["mark"], p["pack"]
    out = ['<svg xmlns="http://www.w3.org/2000/svg" width="120" height="120" viewBox="0 0 120 120">',
           '<g stroke="#4A3525" stroke-width="2.5" stroke-linejoin="round">']
    if pack == "pillow":
        out += [f'<path d="M30 15 H90 L96 31 L92 103 H28 L24 31 Z" fill="{color}"/>',
                f'<path d="M27 15 H93 V25 H27 Z M29 94 H91 V104 H29 Z" fill="{accent}"/>',
                '<path d="M31 18 H89 M31 21 H89 M32 98 H88 M32 101 H88" fill="none" stroke-width="1"/>',
                f'<path d="M25 37 L95 27 L94 47 L26 56 Z" fill="{accent}" stroke="none" opacity=".9"/>',
                '<rect x="35" y="39" width="50" height="38" rx="8" fill="#F7EBD4"/>',
                '<path d="M32 31 L37 91" stroke="#FFFFFF" opacity=".35" stroke-width="4"/>',
                text(60, 35, brand, 8, "#F9F0DE"), text(60, 64, mark, 25, label_ink(color)),
                motif(category, accent), '</g>']
    elif pack == "pouch":
        out += [f'<path d="M29 18 H91 L96 101 Q60 110 24 101 Z" fill="{color}"/>',
                f'<path d="M29 18 H91 V33 H29 Z" fill="{accent}"/>',
                '<path d="M32 27 H88 M34 31 H86" fill="none" stroke-width="1.3"/>',
                '<rect x="35" y="37" width="50" height="29" rx="7" fill="#F7EBD4"/>',
                f'<path d="M31 69 Q60 61 89 69 L91 96 Q60 102 29 96 Z" fill="#F5E6C8" opacity=".72"/>',
                text(60, 27, brand, 8, "#4A3525"), text(60, 58, mark, 22, label_ink(color)),
                motif(category, accent), '<path d="M34 96 Q60 101 86 96" fill="none" opacity=".45"/>', '</g>']
    elif pack == "box":
        out += [f'<rect x="20" y="20" width="80" height="82" rx="5" fill="{color}"/>',
                f'<path d="M20 20 L30 13 H100 V94 L100 20 Z" fill="{accent}" opacity=".8"/>',
                '<path d="M29 21 V99 M91 22 V96" fill="none" opacity=".35"/>',
                '<rect x="31" y="34" width="58" height="45" rx="6" fill="#F7EBD4"/>',
                text(60, 31, brand, 9, "#F9F0DE"), text(60, 62, mark, 25, label_ink(color)),
                motif(category, accent), '</g>']
    elif pack == "tin":
        out += ['<rect x="17" y="22" width="86" height="78" rx="15" fill="#B8B2A4"/>',
                f'<rect x="22" y="27" width="76" height="68" rx="12" fill="{color}"/>',
                '<path d="M25 34 Q60 24 95 34" fill="none" stroke="#FFFFFF" opacity=".4"/>',
                f'<ellipse cx="60" cy="60" rx="29" ry="25" fill="{accent}"/>',
                text(60, 42, brand, 8, "#F9F0DE"), text(60, 68, mark, 27, "#4A3525"),
                motif(category, "#F5E6C8"), '</g>']
    elif pack == "twist":
        out += [f'<path d="M35 43 L12 27 L17 60 L12 93 L35 77 Z M85 43 L108 27 L103 60 L108 93 L85 77 Z" fill="{accent}"/>',
                f'<rect x="31" y="35" width="58" height="51" rx="13" fill="{color}"/>',
                f'<path d="M39 36 L48 85 M72 35 L81 84" stroke="{accent}" stroke-width="8" opacity=".8"/>',
                '<rect x="43" y="43" width="34" height="34" rx="9" fill="#F7EBD4"/>',
                text(60, 67, mark, 24, label_ink(color)), text(60, 95, brand, 8, "#4A3525"), '</g>']
    elif pack == "bar":
        out += [f'<rect x="27" y="13" width="66" height="94" rx="5" fill="{color}"/>',
                '<path d="M31 20 H89 V42 H31 Z M31 88 H89 V101 H31 Z" fill="#4A3525" opacity=".45"/>',
                '<path d="M43 20 V42 M60 20 V42 M77 20 V42 M31 31 H89" fill="none" stroke-width="1.4"/>',
                f'<path d="M27 44 H93 V84 H27 Z" fill="{accent}"/>',
                '<rect x="35" y="48" width="50" height="29" rx="4" fill="#F7EBD4"/>',
                text(60, 68, mark, 23, label_ink(color)), text(60, 96, brand, 8, "#F9F0DE"),
                '<path d="M30 15 L37 104" stroke="#FFFFFF" opacity=".25" stroke-width="3"/>', '</g>']
    elif pack == "cup":
        out += [f'<circle cx="60" cy="60" r="48" fill="{accent}"/>',
                f'<circle cx="60" cy="60" r="42" fill="{color}"/>',
                '<circle cx="60" cy="60" r="35" fill="#F7EBD4"/>',
                f'<path d="M25 48 A38 38 0 0 1 92 39" fill="none" stroke="{accent}" stroke-width="8"/>',
                text(60, 48, brand, 9, "#4A3525"), text(60, 76, mark, 28, label_ink(color)),
                motif(category, accent), '<path d="M79 20 L91 12 L96 25" fill="#F7EBD4"/>', '</g>']
    elif pack == "bottle":
        out += [f'<rect x="48" y="7" width="24" height="15" rx="4" fill="{accent}"/>',
                '<path d="M50 11 V20 M56 10 V21 M63 10 V21 M69 11 V20" stroke-width="1"/>',
                f'<path d="M49 22 H71 V35 L83 50 V105 H37 V50 L49 35 Z" fill="{color}"/>',
                f'<path d="M37 57 H83 V94 H37 Z" fill="{accent}"/>',
                '<rect x="43" y="61" width="34" height="28" rx="6" fill="#F7EBD4"/>',
                text(60, 82, mark, 23, label_ink(color)), text(60, 49, brand, 8, "#F9F0DE"),
                '<path d="M45 43 V101" stroke="#FFFFFF" opacity=".3" stroke-width="4"/>', '</g>']
    elif pack == "carton":
        out += [f'<path d="M32 35 H88 V106 H32 Z" fill="{color}"/>',
                f'<path d="M32 35 L43 13 H77 L88 35 Z" fill="{accent}"/>',
                '<path d="M43 13 L60 25 L77 13 M60 25 V35" fill="none"/>',
                f'<path d="M32 45 H88 V91 H32 Z" fill="{accent}" opacity=".85"/>',
                '<rect x="40" y="51" width="40" height="34" rx="5" fill="#F7EBD4"/>',
                text(60, 75, mark, 25, label_ink(color)), text(60, 42, brand, 8, "#4A3525"),
                motif(category, "#F5E6C8"), '</g>']
    out.append('</svg>')
    return "\n".join(out) + "\n"


def main():
    SVG_DIR.mkdir(parents=True, exist_ok=True)
    records = []
    for values in PRODUCTS:
        keys = ("id", "category", "name", "brand", "mark", "pack", "weight", "product_scale", "color", "accent", "package_note")
        p = dict(zip(keys, values))
        p["svg"] = f"snack_{p['id']}.svg"
        records.append(p)
        (SVG_DIR / p["svg"]).write_text(render(p), encoding="utf-8")
    data = {
        "schema_version": 2,
        "design_notice": "所有名称、子品牌和包装图案均为原创；只参考品类通用包装结构，不复制真实品牌、商标、角色或标志性包装。",
        "categories": [{"id": cid, "name": name, "packaging_reference": ref} for cid, name, ref in CATEGORIES],
        "snacks": records,
    }
    DATA_PATH.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"generated {len(records)} original snack packages across {len(CATEGORIES)} categories")


if __name__ == "__main__":
    main()
