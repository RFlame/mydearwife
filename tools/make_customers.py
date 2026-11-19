#!/usr/bin/env python3
"""生成 12 位原创顾客配置与无文字 SVG 半身像。

仅使用通用几何形状和原创配色；不引用真实人物、品牌或第三方角色。
运行：python3 -I tools/make_customers.py（会覆盖生成的 JSON 和头像）。
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

CUSTOMERS = [
    {"id": "aunt_chen", "name": "陈阿姨", "base_type": "normal", "personality": "精打细算", "patience_mult": 1.12, "combo_window_mult": 1.0,
     "description": "布袋里总装着优惠券，最爱比较散装果干的单价。看起来不急，找到实惠才会眉开眼笑。",
     "lines": ["老板，称准一点呀！", "今天的果干新鲜吗？", "实惠才是最好的零食。"],
     "skin": "#F2BE91", "shirt": "#C95645", "accent": "#F2C14E", "hair": "#3A2928", "hair_style": "bob", "accessory": "glasses"},
    {"id": "grandpa_lin", "name": "林爷爷", "base_type": "normal", "personality": "慢条斯理", "patience_mult": 1.22, "combo_window_mult": 1.1,
     "description": "拎着保温杯慢慢挑点心，愿意多等一会儿。从容的节奏也让连续分拣有更宽的连击窗口。",
     "lines": ["不着急，慢慢称。", "给我留几块酥点的。", "这店有从前的味道。"],
     "skin": "#E8B98E", "shirt": "#55786B", "accent": "#D9C59A", "hair": "#E8E0D2", "hair_style": "side", "accessory": "moustache"},
    {"id": "tian_tian", "name": "甜甜", "base_type": "normal", "personality": "甜食收藏家", "patience_mult": 1.05, "combo_window_mult": 1.08,
     "description": "为收集不同糖纸而来，看到彩色糖果就心情大好。甜味带来的好心情会延长连击节奏。",
     "lines": ["草莓味的也要！", "这张糖纸我还没有！", "今天也要甜甜的。"],
     "skin": "#F5C6A5", "shirt": "#E7839A", "accent": "#FFD56A", "hair": "#55352E", "hair_style": "ponytail", "accessory": "hairclip"},
    {"id": "aunt_hua", "name": "花婶", "base_type": "normal", "personality": "热心话痨", "patience_mult": 1.15, "combo_window_mult": 1.12,
     "description": "街坊消息和零食安利一样多，聊起来就忘了时间。她的热情鼓劲让连击窗口更宽松。",
     "lines": ["这个我邻居也说好吃！", "慢慢来，我陪你聊聊。", "多给你介绍几位客人！"],
     "skin": "#EFB98F", "shirt": "#E88945", "accent": "#7BAA65", "hair": "#4B2C29", "hair_style": "curly", "accessory": "earrings"},
    {"id": "xiao_man", "name": "小满", "base_type": "hurried", "personality": "风风火火", "patience_mult": 0.85, "combo_window_mult": 0.95,
     "description": "下课铃一响就冲进店里，耐心只有普通顾客的 85%。手速够快才能跟上她的催促。",
     "lines": ["搞快点，要上课啦！", "先称最上面的！", "叮叮咚，快一点！"],
     "skin": "#F3C29E", "shirt": "#4D8EC9", "accent": "#F3D34A", "hair": "#30282A", "hair_style": "short", "accessory": "headband"},
    {"id": "student_xi", "name": "小希", "base_type": "hurried", "personality": "考前冲刺", "patience_mult": 0.88, "combo_window_mult": 1.05,
     "description": "抱着习题册采购熬夜补给，赶时间却很专注。耐心稍短，但专注让连击窗口略有延长。",
     "lines": ["下一套卷子还等着我！", "麻烦麻利一点哦。", "饼干和牛奶，补充能量！"],
     "skin": "#F0BE9B", "shirt": "#6A72B5", "accent": "#E9E4D4", "hair": "#342D36", "hair_style": "long", "accessory": "round_glasses"},
    {"id": "courier_lu", "name": "阿路", "base_type": "hurried", "personality": "分秒必争", "patience_mult": 0.82, "combo_window_mult": 0.9,
     "description": "送货途中顺手补给，头盔都来不及摘。全场最赶时间，需要更利落地连续点击。",
     "lines": ["下一单马上超时啦！", "能边称边装袋吗？", "快一点，谢谢老板！"],
     "skin": "#DDA477", "shirt": "#E6B93F", "accent": "#3A5B73", "hair": "#332B28", "hair_style": "cap", "accessory": "headphones"},
    {"id": "night_owl", "name": "阿夜", "base_type": "hurried", "personality": "夜猫补货", "patience_mult": 0.9, "combo_window_mult": 1.08,
     "description": "赶在夜班开始前囤饮料和卤味，外表困倦，结账却很急。熟悉夜班节奏，连击窗口稍长。",
     "lines": ["夜班前最后补一波。", "柠檬茶放上面就好。", "速度快一点，我要上班啦。"],
     "skin": "#C98F6D", "shirt": "#35445F", "accent": "#9B72C7", "hair": "#25232E", "hair_style": "spiky", "accessory": "earphones"},
    {"id": "boss_wang", "name": "王老板", "base_type": "rich", "personality": "豪爽囤货", "patience_mult": 1.0, "combo_window_mult": 1.0,
     "description": "谈成生意就来扫一篮招待客人，喜欢的零食从不只买一包，结账时干脆利落。",
     "lines": ["这些我全要了！", "好吃的尽管装上！", "请客就不能小气。"],
     "skin": "#DFA77F", "shirt": "#6F3E3C", "accent": "#D6A73C", "hair": "#292526", "hair_style": "side", "accessory": "moustache"},
    {"id": "foodie_qi", "name": "小七", "base_type": "rich", "personality": "猎奇美食家", "patience_mult": 1.08, "combo_window_mult": 1.1,
     "description": "专程寻找没吃过的新口味，愿意为特色零食买单。发现新品时格外兴奋，连击节奏更宽松。",
     "lines": ["这个口味我没吃过！", "新奇的都给我来一点。", "美味值得认真称重。"],
     "skin": "#F0B995", "shirt": "#3C8C86", "accent": "#F29D62", "hair": "#653B32", "hair_style": "bun", "accessory": "star_earrings"},
    {"id": "teacher_bai", "name": "白老师", "base_type": "rich", "personality": "乐于分享", "patience_mult": 1.12, "combo_window_mult": 1.12,
     "description": "总给学生和邻居带一篮零食，喜欢把大包分成小份。温和又慷慨，等待时很有耐心。",
     "lines": ["分着装，孩子们好分享。", "每样都来一点吧。", "好吃的要大家一起尝。"],
     "skin": "#EAB994", "shirt": "#B85F68", "accent": "#E5CF9C", "hair": "#4B3833", "hair_style": "bun", "accessory": "glasses"},
    {"id": "fitness_jun", "name": "阿骏", "base_type": "rich", "personality": "品质至上", "patience_mult": 1.05, "combo_window_mult": 1.05,
     "description": "训练后认真挑选坚果和肉干，注重配料也讲究效率。为高品质买单，但不喜欢混装出错。",
     "lines": ["坚果和肉干分开称。", "品质好就值得买。", "训练后的补给不能马虎。"],
     "skin": "#B97B58", "shirt": "#446B4B", "accent": "#D7E26D", "hair": "#242426", "hair_style": "short", "accessory": "sweatband"},
]


def hair_svg(c):
    color = c["hair"]
    style = c["hair_style"]
    top = f'<path d="M45 79 Q42 24 91 23 Q139 24 136 79 Q119 49 90 49 Q62 50 45 79Z" fill="{color}"/>'
    if style == "bob":
        return top + f'<path d="M44 61 Q31 99 47 137 L58 127 L55 65Z M136 61 Q149 99 133 137 L122 127 L125 65Z" fill="{color}"/>'
    if style == "ponytail":
        return top + f'<path d="M130 49 Q168 51 153 118 Q142 136 132 112 Q151 80 130 49Z" fill="{color}"/><circle cx="139" cy="52" r="8" fill="{c["accent"]}"/>'
    if style == "curly":
        circles = [(48, 48, 18), (65, 31, 19), (89, 27, 20), (113, 31, 19), (132, 49, 18), (43, 70, 14), (137, 70, 14)]
        return "".join(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{color}"/>' for x, y, r in circles)
    if style == "cap":
        return f'<path d="M42 58 Q47 13 95 17 Q132 20 139 58Z" fill="{c["shirt"]}"/><path d="M38 58 Q98 46 151 68 Q115 78 46 69Z" fill="{c["accent"]}"/>' + top
    if style == "long":
        return top + f'<path d="M44 61 Q30 124 45 166 L65 152 L58 61Z M136 61 Q150 124 135 166 L115 152 L122 61Z" fill="{color}"/>'
    if style == "bun":
        return f'<circle cx="92" cy="17" r="22" fill="{color}"/>' + top
    if style == "spiky":
        return f'<path d="M43 70 L39 37 L58 45 L62 19 L78 36 L94 10 L104 34 L127 17 L127 42 L146 37 L136 75 Q113 45 89 48 Q62 48 43 70Z" fill="{color}"/>'
    if style == "side":
        return f'<path d="M44 72 Q43 28 89 23 Q132 20 140 63 Q112 52 95 34 Q78 58 44 72Z" fill="{color}"/>'
    return top


def accessory_svg(c):
    kind = c["accessory"]
    accent = c["accent"]
    if kind in ("glasses", "round_glasses"):
        rx = 14 if kind == "round_glasses" else 16
        return f'<g fill="none" stroke="#44352F" stroke-width="4"><rect x="54" y="72" width="{rx*2}" height="20" rx="8"/><rect x="94" y="72" width="{rx*2}" height="20" rx="8"/><path d="M84 80 H96 M53 77 L43 72 M126 77 L137 72"/></g>'
    if kind == "moustache":
        return '<path d="M90 108 Q76 96 65 108 Q76 119 90 112 Q104 119 115 108 Q104 96 90 108Z" fill="#55413A"/>'
    if kind in ("hairclip", "star_earrings"):
        if kind == "hairclip":
            return f'<path d="M118 43 L124 52 L135 53 L127 61 L129 72 L118 67 L108 72 L110 61 L102 53 L113 52Z" fill="{accent}"/>'
        return f'<path d="M44 107 l4 8 9 1-7 6 2 9-8-5-8 5 2-9-7-6 9-1Z M136 107 l4 8 9 1-7 6 2 9-8-5-8 5 2-9-7-6 9-1Z" fill="{accent}"/>'
    if kind == "earrings":
        return f'<circle cx="43" cy="111" r="6" fill="{accent}"/><circle cx="137" cy="111" r="6" fill="{accent}"/>'
    if kind in ("headband", "sweatband"):
        return f'<path d="M47 58 Q90 31 135 58" fill="none" stroke="{accent}" stroke-width="9"/><path d="M48 58 L40 78 M132 58 L140 78" stroke="{accent}" stroke-width="7"/>'
    if kind in ("headphones", "earphones"):
        if kind == "headphones":
            return f'<path d="M40 85 Q35 38 90 33 Q145 38 140 85" fill="none" stroke="{accent}" stroke-width="8"/><rect x="32" y="75" width="15" height="35" rx="7" fill="{accent}"/><rect x="133" y="75" width="15" height="35" rx="7" fill="{accent}"/>'
        return f'<path d="M44 103 Q48 133 70 144 M136 103 Q132 133 110 144" fill="none" stroke="{accent}" stroke-width="3"/><circle cx="43" cy="103" r="5" fill="{accent}"/><circle cx="137" cy="103" r="5" fill="{accent}"/>'
    return ""


def portrait(c):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="180" height="210" viewBox="0 0 180 210">
<ellipse cx="90" cy="199" rx="69" ry="8" fill="#3B2518" opacity=".2"/>
<path d="M25 207 Q27 148 69 139 L111 139 Q153 148 155 207Z" fill="{c['shirt']}" stroke="#49342C" stroke-width="4"/>
<path d="M65 142 L90 174 L115 142 L106 134 L74 134Z" fill="{c['accent']}"/>
<path d="M72 119 L70 145 Q90 159 110 145 L108 119Z" fill="{c['skin']}" stroke="#49342C" stroke-width="3"/>
<circle cx="43" cy="91" r="12" fill="{c['skin']}" stroke="#49342C" stroke-width="3"/>
<circle cx="137" cy="91" r="12" fill="{c['skin']}" stroke="#49342C" stroke-width="3"/>
<ellipse cx="90" cy="83" rx="47" ry="57" fill="{c['skin']}" stroke="#49342C" stroke-width="4"/>
{hair_svg(c)}
<path d="M61 67 Q70 61 78 67 M102 67 Q110 61 119 67" fill="none" stroke="#49342C" stroke-width="4" stroke-linecap="round"/>
<circle cx="70" cy="82" r="4" fill="#342927"/><circle cx="110" cy="82" r="4" fill="#342927"/>
<path d="M86 91 Q90 96 95 91" fill="none" stroke="#B8795F" stroke-width="3" stroke-linecap="round"/>
<path d="M75 111 Q90 123 106 110" fill="none" stroke="#9C4D48" stroke-width="4" stroke-linecap="round"/>
<circle cx="58" cy="101" r="8" fill="#E8897D" opacity=".35"/><circle cx="122" cy="101" r="8" fill="#E8897D" opacity=".35"/>
{accessory_svg(c)}
<path d="M34 186 Q50 170 63 186 M117 186 Q130 170 146 186" fill="none" stroke="{c['accent']}" stroke-width="5" opacity=".8"/>
</svg>'''


def main():
    data_dir = ROOT / "data"
    art_dir = ROOT / "assets" / "svg"
    public = []
    for c in CUSTOMERS:
        item = {k: c[k] for k in ("id", "name", "base_type", "personality", "patience_mult", "combo_window_mult", "description", "lines")}
        item["avatar"] = "customer_%s.svg" % c["id"]
        public.append(item)
        (art_dir / item["avatar"]).write_text(portrait(c), encoding="utf-8")
    payload = {"schema_version": 1, "customers": public}
    (data_dir / "customers.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("generated %d original customers" % len(public))


if __name__ == "__main__":
    main()
