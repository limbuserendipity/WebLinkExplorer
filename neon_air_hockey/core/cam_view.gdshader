shader_type canvas_item;
render_mode unshaded;
// Слабый неоновый ретро-фильтр для кадра с вебкамеры: тонирование в два
// неоновых цвета, хроматическая аберрация, скан-линии, полоса развёртки,
// лёгкий шум и виньетка. strength = 0 вернёт исходный кадр.

uniform float strength : hint_range(0.0, 1.0) = 0.55;
uniform vec3 tint_low : source_color = vec3(0.16, 0.03, 0.42);
uniform vec3 tint_high : source_color = vec3(0.35, 1.0, 1.0);
uniform float aberration = 1.4;      // сдвиг каналов, в пикселях текстуры
uniform float scan = 0.34;           // глубина скан-линий
uniform float noise = 0.07;          // шум сенсора
uniform float vignette = 0.55;       // затемнение по краям
uniform float sweep = 0.10;          // бегущая полоса развёртки
uniform float time_s = 0.0;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(41.7, 289.3))) * 43758.5453);
}

void fragment() {
	vec2 px = TEXTURE_PIXEL_SIZE * aberration;
	vec3 c;
	c.r = texture(TEXTURE, UV + vec2(px.x, 0.0)).r;
	c.g = texture(TEXTURE, UV).g;
	c.b = texture(TEXTURE, UV - vec2(px.x, 0.0)).b;

	float lum = dot(c, vec3(0.299, 0.587, 0.114));
	// двухцветная неоновая тонировка: тени в фиолет, света в циан
	vec3 duo = mix(tint_low, tint_high, smoothstep(0.08, 0.92, lum)) * (0.28 + 1.20 * lum);
	vec3 col = mix(c, duo, strength * 0.85);

	// скан-линии по строкам исходного кадра
	float row = UV.y / TEXTURE_PIXEL_SIZE.y;
	float sl = 0.5 + 0.5 * sin(row * 1.5708);
	col *= 1.0 - scan * 0.5 * sl;

	// медленно ползущая полоса развёртки
	float band = fract(time_s * 0.14);
	col += tint_high * sweep * smoothstep(0.05, 0.0, abs(UV.y - band));

	// шум сенсора
	col += (hash21(UV * 640.0 + vec2(floor(time_s * 24.0))) - 0.5) * noise * strength;

	// виньетка
	vec2 d = UV - vec2(0.5);
	col *= 1.0 - vignette * dot(d, d) * 1.6 * (0.45 + strength);

	COLOR = vec4(col, 1.0);
}
