//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
// 
// UIDetectMulti By Kaiser
// v. 1.6.0
// License: CC By 4.0
// Based on work from Brussels1
//
// UIDetectMulti is configured via the file UIDetectMulti.fxh. Please look
// there for a full description and usage of this shader.
//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

//Requirements
#include "ReShadeUI.fxh"
#include "ReShade.fxh"
#include "UIDetectMulti.fxh"
#include "DrawText.fxh"

//Reshade.fxh version independence
#undef BUFFER_PIXEL_SIZE
#define BUFFER_PIXEL_SIZE float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT)
texture texBackBuffer : COLOR;
sampler BackBuffer { Texture = texBackBuffer; };

//Sliders
//One UI element's four sliders: RGB tolerance, frames to activate and deactivate,
//and the "every pixel" flag. The category label follows the element number.
#define UIDM_STR(x) #x
#define UIDM_ELEM(e) \
	uniform float3 tolerance##e < __UNIFORM_SLIDER_FLOAT3 \
		ui_label = "RGB tolerance"; \
		ui_category = "Mask " UIDM_STR(e) " Tolerances"; \
		ui_category_closed = true; \
		ui_min = 1; ui_max = 255; \
		ui_step = 1; \
	> = 1; \
	uniform float FA##e < __UNIFORM_SLIDER_FLOAT1 \
		ui_label = "Frames to activate"; \
		ui_tooltip = "How many frames a UI element has to be on screen to activate the mask"; \
		ui_category = "Mask " UIDM_STR(e) " Tolerances"; \
		ui_category_closed = true; \
		ui_min = 1; ui_max = 60; \
		ui_step = 1; \
	> = 1; \
	uniform float FD##e < __UNIFORM_SLIDER_FLOAT1 \
		ui_label = "Frames to deactivate"; \
		ui_tooltip = "How many frames a UI element has to be off screen to de-activate the mask"; \
		ui_category = "Mask " UIDM_STR(e) " Tolerances"; \
		ui_category_closed = true; \
		ui_min = 1; ui_max = 60; \
		ui_step = 1; \
	> = 1; \
	uniform bool Every##e < __UNIFORM_SLIDER_BOOL1 \
		ui_label = "Does every pixel needs to be showing to activate?"; \
		ui_category = "Mask " UIDM_STR(e) " Tolerances"; \
		ui_category_closed = true; \
	> = 0;

UIDM_ELEM(1)

UIDM_ELEM(2)

UIDM_ELEM(3)

#if (UIDM_MASK_COUNT > 1)
	UIDM_ELEM(4)
	UIDM_ELEM(5)
	UIDM_ELEM(6)
#endif

#if (UIDM_MASK_COUNT > 2)
	UIDM_ELEM(7)
	UIDM_ELEM(8)
	UIDM_ELEM(9)
#endif

#if (UIDM_MASK_COUNT > 3)
	UIDM_ELEM(10)
	UIDM_ELEM(11)
	UIDM_ELEM(12)
#endif

#if (UIDM_MASK_COUNT > 4)
	UIDM_ELEM(13)
	UIDM_ELEM(14)
	UIDM_ELEM(15)
#endif

#if (UIDM_DIAGNOSTICS == 1)
	uniform float fPixelPosX < __UNIFORM_SLIDER_FLOAT1
		ui_label = "Pixel X-Position";
		ui_category = "Pixel Selection";
		ui_category_closed = true;
		ui_min = 0; ui_max = BUFFER_WIDTH;
		ui_step = 1;
	> = 100;

	uniform float fPixelPosY < __UNIFORM_SLIDER_FLOAT1
		ui_label = "Pixel Y-Position";
		ui_category = "Pixel Selection";
		ui_category_closed = true;
		ui_min = 0; ui_max = BUFFER_HEIGHT;
		ui_step = 1;
	> = 100;
	
	uniform float3 CrossColor < __UNIFORM_COLOR_FLOAT3
		ui_label = "Crosshair Color";
		ui_category = "Pixel Selection";
		ui_category_closed = true;
		ui_min = 0; ui_max = 255;
		ui_step = 1;
	> = 1;

	uniform bool BlackFont <
		ui_label = "Font color";
		ui_tooltip = "Check for Black font, Uncheck for White font";
		ui_category = "Pixel Selection";
		ui_category_closed = true;
	> = true;
#endif

//textures and samplers
//One mask slot's textures and samplers: the mask image itself, the 1x1 detect target
//its elements accumulate into, and the 1x1 timer target. The `source=` PNG name is
//passed in because slot 1's file has no number (UIDETECTMASKRGBMULTI.png), while the
//texture and sampler names are all suffixed so every slot is spelled the same way.
#define UIDM_SLOT(n, png) \
	texture texUIDetectMaskMulti##n <source=UIDM_STR(png);> { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format=RGBA8; }; \
	sampler UIDetectMaskMulti##n { Texture = texUIDetectMaskMulti##n; }; \
	texture texUIDetectMulti##n { Width = 1; Height = 1; Format = RGBA8; }; \
	sampler UIDetectMulti##n { Texture = texUIDetectMulti##n; }; \
	texture texUIDetectTimer##n { Width = 1; Height = 1; Format = RGBA8; }; \
		sampler UIDetectTimer##n { Texture = texUIDetectTimer##n; };

//One slot's two trivial timer shaders: the setup pass that seeds the rolling counter
//from the Every flags, and the pass that forwards the detect result to the timer target.
#define UIDM_TIMER_SHADERS(n, e1, e2, e3) \
	float4 PS_UIDetectTimerSetup##n(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target \
	{ \
		float3 colorOrig = 1 - float3(Every##e1, Every##e2, Every##e3); \
		return float4(colorOrig, 1); \
	} \
	\
	float4 PS_UIDetectTimer##n(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target \
	{ \
		float3 uicolors = tex2D(UIDetectMulti##n, float2(0,0)).rgb; \
		return float4(uicolors, 1); \
	}

texture texColorBeforeMulti { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; };
sampler ColorBeforeMulti { Texture = texColorBeforeMulti; };
UIDM_SLOT(1, UIDETECTMASKRGBMULTI.png)

#if (UIDM_DIAGNOSTICS == 1)
	texture textextcolor { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; };
	sampler textcolor { Texture = textextcolor; };
	texture textextcolor2 { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; };
	sampler textcolor2 { Texture = textextcolor2; };
	texture texColorOrigMulti { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; };
	sampler ColorOrigMulti { Texture = texColorOrigMulti; };
#endif

#if (UIDM_MASK_COUNT > 1)
	UIDM_SLOT(2, UIDETECTMASKRGBMULTI2.png)
#endif

#if (UIDM_MASK_COUNT > 2)
	UIDM_SLOT(3, UIDETECTMASKRGBMULTI3.png)
#endif

#if (UIDM_MASK_COUNT > 3)
	UIDM_SLOT(4, UIDETECTMASKRGBMULTI4.png)
#endif

#if (UIDM_MASK_COUNT > 4)
	UIDM_SLOT(5, UIDETECTMASKRGBMULTI5.png)
#endif

//pixel shaders
//Scans the pixel table for the three UI elements of one mask slot. `base` is the
//slot's first UINr (1, 4, 7, 10, 13); the other two elements are base+1 and base+2.
//Each element carries its own RGB tolerance, matching the mask channel it feeds.
float3 UIDM_DetectChannels(int base, float3 toleranceR, float3 toleranceG, float3 toleranceB, float3 every, float3 FTA, float3 uicolors)
{
	float3 pixelColor, uiPixelColor, diff;
	float2 pixelCoord;
	int uinumber = -1;
	float3 uiDetected = every;

	for (int i=0; i < PIXELNUMBER; i++){
		if (UIPixelCoord_UINr[i].z == base){uinumber = i; break;}
	}
	if (uinumber != -1){
		for (int i=0; i < 3 && uinumber < PIXELNUMBER; i++){
			pixelCoord = UIPixelCoord_UINr[uinumber].xy * BUFFER_PIXEL_SIZE;
			pixelColor = round(tex2D(BackBuffer, float2(pixelCoord)).rgb * 255);
			uiPixelColor = UIPixelRGB[uinumber].rgb;
			diff = abs(pixelColor - uiPixelColor);
			if (every.x == 0 && diff.r < toleranceR.r && diff.g < toleranceR.g && diff.b < toleranceR.b && UIPixelCoord_UINr[uinumber].z == base) uiDetected.x = 1;
			if (every.y == 0 && diff.r < toleranceG.r && diff.g < toleranceG.g && diff.b < toleranceG.b && UIPixelCoord_UINr[uinumber].z == base + 1) uiDetected.y = 1;
			if (every.z == 0 && diff.r < toleranceB.r && diff.g < toleranceB.g && diff.b < toleranceB.b && UIPixelCoord_UINr[uinumber].z == base + 2) uiDetected.z = 1;
			if (every.x == 1 && diff.r > toleranceR.r && diff.g > toleranceR.g && diff.b > toleranceR.b && UIPixelCoord_UINr[uinumber].z == base) uiDetected.x = 0;
			if (every.y == 1 && diff.r > toleranceG.r && diff.g > toleranceG.g && diff.b > toleranceG.b && UIPixelCoord_UINr[uinumber].z == base + 1) uiDetected.y = 0;
			if (every.z == 1 && diff.r > toleranceB.r && diff.g > toleranceB.g && diff.b > toleranceB.b && UIPixelCoord_UINr[uinumber].z == base + 2) uiDetected.z = 0;
			if (uinumber < PIXELNUMBER - 1){
				if (UIPixelCoord_UINr[uinumber].z == UIPixelCoord_UINr[uinumber + 1].z){i -= 1;};
			}
			uinumber += 1;
		}

		if (every.x == 0){if (uiDetected.x == 1){uicolors.r -= FTA.x;}else{uicolors.r += FTA.x;}}
		if (every.y == 0){if (uiDetected.y == 1){uicolors.g -= FTA.y;}else{uicolors.g += FTA.y;}}
		if (every.z == 0){if (uiDetected.z == 1){uicolors.b -= FTA.z;}else{uicolors.b += FTA.z;}}
		if (every.x == 1){if (uiDetected.x == 0){uicolors.r += FTA.x;}else{uicolors.r -= FTA.x;}}
		if (every.y == 1){if (uiDetected.y == 0){uicolors.g += FTA.y;}else{uicolors.g -= FTA.y;}}
		if (every.z == 1){if (uiDetected.z == 0){uicolors.b += FTA.z;}else{uicolors.b -= FTA.z;}}
	}
	return uicolors;
}

//UIDetectMulti
#if (UIDM_DIAGNOSTICS == 1)
	float4 State_Pixel_Color(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		float res = 0.0;
		//Layout was authored for 1080p, scale it so the readout keeps its place and size at other resolutions
		float uiScale = BUFFER_HEIGHT / 1080.0;
		float2 textPos = float2(800.0, 100.0) * uiScale;
		float textSize = 50.0 * uiScale;
		float textStep = 34.0 * uiScale;
		
		float2 pixelCoord = float2(fPixelPosX, fPixelPosY) * BUFFER_PIXEL_SIZE;
		float3 pixelColor = round(tex2D(BackBuffer, pixelCoord).rgb * 255);
	
		uint Red = trunc(pixelColor.x);
		uint Green = trunc(pixelColor.y);
		uint Blue = trunc(pixelColor.z);
	
		int Red3 = (Red - (Red % 100)) / 100;
		int Red2 = ((Red % 100) - (Red % 10)) / 10;
		int Red1 = Red % 10;
		int Green3 = (Green - (Green % 100)) / 100;
		int Green2 = ((Green % 100) - (Green % 10)) / 10;
		int Green1 = Green % 10;
		int Blue3 = (Blue - (Blue % 100)) / 100;
		int Blue2 = ((Blue % 100) - (Blue % 10)) / 10;
		int Blue1 = Blue % 10;
		
		int line0[10]  = { __R, __E, __D, __Colon, __Space, __Space, __Space, Red3 + 16, Red2 + 16, Red1 + 16 }; //Red
		int line1[10]  = { __G, __R, __E, __E, __N, __Colon, __Space, Green3 + 16, Green2 + 16, Green1 + 16 }; //Green
		int line2[10]  = { __B, __L, __U, __E, __Colon, __Space, __Space, Blue3 + 16, Blue2 + 16, Blue1 + 16 }; //Blue
		DrawText_String(textPos, textSize, 1, texcoord,  line0, 10, res);
		DrawText_String(textPos + float2(0.0, textStep), textSize, 1, texcoord,  line1, 10, res);
		DrawText_String(textPos + float2(0.0, textStep * 2.0), textSize, 1, texcoord,  line2, 10, res);
		return res;
	}
	
	float4 Fontinvert(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		float3 colors = tex2D(textcolor, texcoord).rgb;
		return float4(1.0 - colors, 1.0);
	}
	
	float3 Crosshair(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		float3 color = 0;
		float3 crosshair = CrossColor;
		float3 colorOrig = tex2D(BackBuffer, texcoord).rgb;
		float2 pixelCoord = float2(fPixelPosX, fPixelPosY) * BUFFER_PIXEL_SIZE;
		float mask;
		int Xtest = 0;
		int Ytest = 0;
		if (abs((texcoord.x / BUFFER_PIXEL_SIZE.x) - (pixelCoord.x / BUFFER_PIXEL_SIZE.x)) < 0.5) Xtest = 1;
		if (abs((texcoord.y / BUFFER_PIXEL_SIZE.y) - (pixelCoord.y / BUFFER_PIXEL_SIZE.y)) < 0.5) Ytest = 1;
		if (Xtest == 1 && Ytest == 1){ Xtest = 0; Ytest = 0;}
		color = lerp(color, crosshair, Xtest);
		color = lerp(color, crosshair, Ytest);
		if(CrossColor.x >= CrossColor.y && CrossColor.x >= CrossColor.z) mask = color.x;
		if(CrossColor.y >= CrossColor.x && CrossColor.y >= CrossColor.z) mask = color.y;
		if(CrossColor.z >= CrossColor.x && CrossColor.z >= CrossColor.y) mask = color.z;
		if(CrossColor.x >= CrossColor.y && CrossColor.x <= CrossColor.z) mask = color.z;
		if(CrossColor.y >= CrossColor.x && CrossColor.y <= CrossColor.z) mask = color.z;
		if(CrossColor.z >= CrossColor.x && CrossColor.z <= CrossColor.y) mask = color.y;
		color = lerp(colorOrig, color, mask);
		return color;
	}
	
	float4 FontTransparancy(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		float3 color;
		float3 colorOrig = tex2D(BackBuffer, texcoord).rgb;
		float mask;
		
		if (BlackFont == true){
			color = tex2D(textcolor, texcoord).rgb;
			mask = saturate(tex2D(textcolor, texcoord).r);
		}
		if (BlackFont == false){
			color = tex2D(textcolor2, texcoord).rgb;
			mask = saturate(1.0 - tex2D(textcolor2, texcoord).r);
		}
		
		color = lerp(colorOrig, color, mask);
		return float4(color, 1.0);
	}
	
	float4 PS_ShowOrigColor(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		float4 colorOrig = tex2D(ColorOrigMulti, texcoord);
		return colorOrig;
	}
#endif

float4 PS_UIDetect1(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float3 uicolors = tex2D(UIDetectTimer1, float2(0,0)).rgb;
	float3 FTA = float3(1 / (FD1 + FA1), 1 / (FD2 + FA2), 1 / (FD3 + FA3));
	return float4(UIDM_DetectChannels(1, tolerance1, tolerance2, tolerance3, float3(Every1, Every2, Every3), FTA, uicolors), 1);
}

UIDM_TIMER_SHADERS(1, 1, 2, 3)

#if (UIDM_MASK_COUNT > 1)
	float4 PS_UIDetect2() : SV_Target
	{
		float3 uicolors = tex2D(UIDetectTimer2, float2(0,0)).rgb;
		float3 FTA = float3(1 / (FD4 + FA4), 1 / (FD5 + FA5), 1 / (FD6 + FA6));
		return float4(UIDM_DetectChannels(4, tolerance4, tolerance5, tolerance6, float3(Every4, Every5, Every6), FTA, uicolors), 1);
	}
	
	UIDM_TIMER_SHADERS(2, 4, 5, 6)
#endif

#if (UIDM_MASK_COUNT > 2)
	float4 PS_UIDetect3() : SV_Target
	{
		float3 uicolors = tex2D(UIDetectTimer3, float2(0,0)).rgb;
		float3 FTA = float3(1 / (FD7 + FA7), 1 / (FD8 + FA8), 1 / (FD9 + FA9));
		return float4(UIDM_DetectChannels(7, tolerance7, tolerance8, tolerance9, float3(Every7, Every8, Every9), FTA, uicolors), 1);
	}
	
	UIDM_TIMER_SHADERS(3, 7, 8, 9)
#endif

#if (UIDM_MASK_COUNT > 3)
	float4 PS_UIDetect4() : SV_Target
	{
		float3 uicolors = tex2D(UIDetectTimer4, float2(0,0)).rgb;
		float3 FTA = float3(1 / (FD10 + FA10), 1 / (FD11 + FA11), 1 / (FD12 + FA12));
		return float4(UIDM_DetectChannels(10, tolerance10, tolerance11, tolerance12, float3(Every10, Every11, Every12), FTA, uicolors), 1);
	}
	
	UIDM_TIMER_SHADERS(4, 10, 11, 12)
#endif

#if (UIDM_MASK_COUNT > 4)
	float4 PS_UIDetect5() : SV_Target
	{
		float3 uicolors = tex2D(UIDetectTimer5, float2(0,0)).rgb;
		float3 FTA = float3(1 / (FD13 + FA13), 1 / (FD14 + FA14), 1 / (FD15 + FA15));
		return float4(UIDM_DetectChannels(13, tolerance13, tolerance14, tolerance15, float3(Every13, Every14, Every15), FTA, uicolors), 1);
	}
	
	UIDM_TIMER_SHADERS(5, 13, 14, 15)
#endif
//end of UIDetectMulti Pixel shader

//Blends one mask channel into the colour, but only while that element's timer is
//below its threshold. One call per RGB channel of a mask slot.
float3 UIDM_BlendChannel(float3 color, float3 colorOrig, float maskChan, float uiChan, float ftd)
{
	if (uiChan < ftd) color = lerp(colorOrig, color, maskChan);
	return color;
}

//UIDetectMulti_Before
#if (UIDM_ANTIBLOOM == 1)
	float4 PS_Antibloom(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		float FTD1 = 1 / ((FD1 + FA1) / FD1);
		float FTD2 = 1 / ((FD2 + FA2) / FD2);
		float FTD3 = 1 / ((FD3 + FA3) / FD3);
		#if (UIDM_MASK_COUNT > 1)
			float FTD4 = 1 / ((FD4 + FA4) / FD4);
			float FTD5 = 1 / ((FD5 + FA5) / FD5);
			float FTD6 = 1 / ((FD6 + FA6) / FD6);
		#endif
		#if (UIDM_MASK_COUNT > 2)		
			float FTD7 = 1 / ((FD7 + FA7) / FD7);
			float FTD8 = 1 / ((FD8 + FA8) / FD8);
			float FTD9 = 1 / ((FD9 + FA9) / FD9);
		#endif
		#if (UIDM_MASK_COUNT > 3)		
			float FTD10 = 1 / ((FD10 + FA10) / FD10);
			float FTD11 = 1 / ((FD11 + FA11) / FD11);
			float FTD12 = 1 / ((FD12 + FA12) / FD12);
		#endif
		#if (UIDM_MASK_COUNT > 4)		
			float FTD13 = 1 / ((FD13 + FA13) / FD13);
			float FTD14 = 1 / ((FD14 + FA14) / FD14);
			float FTD15 = 1 / ((FD15 + FA15) / FD15);
		#endif
		#if (UIDM_INVERT == 0)
			float3 colorOrig = 0;
			float3 color = tex2D(BackBuffer, texcoord).rgb;
		#else
			float3 color = 0;
			float3 colorOrig = tex2D(BackBuffer, texcoord).rgb;
		#endif
		float3 uiMask = tex2D(UIDetectMaskMulti1, texcoord).rgb;
		float3 ui = tex2D(UIDetectMulti1, float2(0,0)).rgb;
		color = UIDM_BlendChannel(color, colorOrig, uiMask.r, ui.r, FTD1); //UINr 1
		color = UIDM_BlendChannel(color, colorOrig, uiMask.g, ui.g, FTD2); //UINr 2
		color = UIDM_BlendChannel(color, colorOrig, uiMask.b, ui.b, FTD3); //UINr 3
		#if (UIDM_MASK_COUNT > 1)
			float3 uiMask2 = tex2D(UIDetectMaskMulti2, texcoord).rgb;
			float3 ui2 = tex2D(UIDetectMulti2, float2(0,0)).rgb;
			color = UIDM_BlendChannel(color, colorOrig, uiMask2.r, ui2.r, FTD4); //UINr 4
			color = UIDM_BlendChannel(color, colorOrig, uiMask2.g, ui2.g, FTD5); //UINr 5
			color = UIDM_BlendChannel(color, colorOrig, uiMask2.b, ui2.b, FTD6); //UINr 6
		#endif
		#if (UIDM_MASK_COUNT > 2)
			float3 uiMask3 = tex2D(UIDetectMaskMulti3, texcoord).rgb;
			float3 ui3 = tex2D(UIDetectMulti3, float2(0,0)).rgb;
			color = UIDM_BlendChannel(color, colorOrig, uiMask3.r, ui3.r, FTD7); //UINr 7
			color = UIDM_BlendChannel(color, colorOrig, uiMask3.g, ui3.g, FTD8); //UINr 8
			color = UIDM_BlendChannel(color, colorOrig, uiMask3.b, ui3.b, FTD9); //UINr 9
		#endif
		#if (UIDM_MASK_COUNT > 3)
			float3 uiMask4 = tex2D(UIDetectMaskMulti4, texcoord).rgb;
			float3 ui4 = tex2D(UIDetectMulti4, float2(0,0)).rgb;
			color = UIDM_BlendChannel(color, colorOrig, uiMask4.r, ui4.r, FTD10); //UINr 10
			color = UIDM_BlendChannel(color, colorOrig, uiMask4.g, ui4.g, FTD11); //UINr 11
			color = UIDM_BlendChannel(color, colorOrig, uiMask4.b, ui4.b, FTD12); //UINr 12
		#endif
		#if (UIDM_MASK_COUNT > 4)
			float3 uiMask5 = tex2D(UIDetectMaskMulti5, texcoord).rgb;
			float3 ui5 = tex2D(UIDetectMulti5, float2(0,0)).rgb;
			color = UIDM_BlendChannel(color, colorOrig, uiMask5.r, ui5.r, FTD13); //UINr 13
			color = UIDM_BlendChannel(color, colorOrig, uiMask5.g, ui5.g, FTD14); //UINr 14
			color = UIDM_BlendChannel(color, colorOrig, uiMask5.b, ui5.b, FTD15); //UINr 15
		#endif
		
		return float4(color, 1.0);
	}
#endif

float4 PS_StoreColor(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	return tex2D(BackBuffer, texcoord);
}

//end of UIDetectMulti_Before Pixel shader

//UIDetectMulti_After
float4 PS_RestoreColor(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float FTD1 = 1 / ((FD1 + FA1) / FD1);
	float FTD2 = 1 / ((FD2 + FA2) / FD2);
	float FTD3 = 1 / ((FD3 + FA3) / FD3);
	#if (UIDM_MASK_COUNT > 1)
		float FTD4 = 1 / ((FD4 + FA4) / FD4);
		float FTD5 = 1 / ((FD5 + FA5) / FD5);
		float FTD6 = 1 / ((FD6 + FA6) / FD6);
	#endif
	#if (UIDM_MASK_COUNT > 2)		
		float FTD7 = 1 / ((FD7 + FA7) / FD7);
		float FTD8 = 1 / ((FD8 + FA8) / FD8);
		float FTD9 = 1 / ((FD9 + FA9) / FD9);
	#endif
	#if (UIDM_MASK_COUNT > 3)		
		float FTD10 = 1 / ((FD10 + FA10) / FD10);
		float FTD11 = 1 / ((FD11 + FA11) / FD11);
		float FTD12 = 1 / ((FD12 + FA12) / FD12);
	#endif
	#if (UIDM_MASK_COUNT > 4)		
		float FTD13 = 1 / ((FD13 + FA13) / FD13);
		float FTD14 = 1 / ((FD14 + FA14) / FD14);
		float FTD15 = 1 / ((FD15 + FA15) / FD15);
	#endif
	#if (UIDM_INVERT == 0)
		float3 colorOrig = tex2D(ColorBeforeMulti, texcoord).rgb;
		float3 color = tex2D(BackBuffer, texcoord).rgb;
	#else
		float3 color = tex2D(ColorBeforeMulti, texcoord).rgb;
		float3 colorOrig = tex2D(BackBuffer, texcoord).rgb;
	#endif
	float3 uiMask = tex2D(UIDetectMaskMulti1, texcoord).rgb;
	float3 ui = tex2D(UIDetectMulti1, float2(0,0)).rgb;
	color = UIDM_BlendChannel(color, colorOrig, uiMask.r, ui.r, FTD1); //UINr 1
	color = UIDM_BlendChannel(color, colorOrig, uiMask.g, ui.g, FTD2); //UINr 2
	color = UIDM_BlendChannel(color, colorOrig, uiMask.b, ui.b, FTD3); //UINr 3
	#if (UIDM_MASK_COUNT > 1)
		float3 uiMask2 = tex2D(UIDetectMaskMulti2, texcoord).rgb;
		float3 ui2 = tex2D(UIDetectMulti2, float2(0,0)).rgb;
		color = UIDM_BlendChannel(color, colorOrig, uiMask2.r, ui2.r, FTD4); //UINr 4
		color = UIDM_BlendChannel(color, colorOrig, uiMask2.g, ui2.g, FTD5); //UINr 5
		color = UIDM_BlendChannel(color, colorOrig, uiMask2.b, ui2.b, FTD6); //UINr 6
	#endif
	#if (UIDM_MASK_COUNT > 2)
		float3 uiMask3 = tex2D(UIDetectMaskMulti3, texcoord).rgb;
		float3 ui3 = tex2D(UIDetectMulti3, float2(0,0)).rgb;
		color = UIDM_BlendChannel(color, colorOrig, uiMask3.r, ui3.r, FTD7); //UINr 7
		color = UIDM_BlendChannel(color, colorOrig, uiMask3.g, ui3.g, FTD8); //UINr 8
		color = UIDM_BlendChannel(color, colorOrig, uiMask3.b, ui3.b, FTD9); //UINr 9
	#endif
	#if (UIDM_MASK_COUNT > 3)
		float3 uiMask4 = tex2D(UIDetectMaskMulti4, texcoord).rgb;
		float3 ui4 = tex2D(UIDetectMulti4, float2(0,0)).rgb;
		color = UIDM_BlendChannel(color, colorOrig, uiMask4.r, ui4.r, FTD10); //UINr 10
		color = UIDM_BlendChannel(color, colorOrig, uiMask4.g, ui4.g, FTD11); //UINr 11
		color = UIDM_BlendChannel(color, colorOrig, uiMask4.b, ui4.b, FTD12); //UINr 12
	#endif
	#if (UIDM_MASK_COUNT > 4)
		float3 uiMask5 = tex2D(UIDetectMaskMulti5, texcoord).rgb;
		float3 ui5 = tex2D(UIDetectMulti5, float2(0,0)).rgb;
		color = UIDM_BlendChannel(color, colorOrig, uiMask5.r, ui5.r, FTD13); //UINr 13
		color = UIDM_BlendChannel(color, colorOrig, uiMask5.g, ui5.g, FTD14); //UINr 14
		color = UIDM_BlendChannel(color, colorOrig, uiMask5.b, ui5.b, FTD15); //UINr 15
	#endif
	return float4(color, 1.0);
}
//End of UIDetectMulti_After Pixel shader

//techniques
//One mask slot's setup pass: seed that slot's rolling counter from its Every flags.
#define UIDM_TIMER_PASS(n) \
	pass { \
		VertexShader = PostProcessVS; \
		PixelShader = PS_UIDetectTimerSetup##n; \
		RenderTarget = texUIDetectTimer##n; \
	}

//One mask slot's two detect passes: run the slot's detect shader, then forward its
//result to the slot's timer target.
#define UIDM_DETECT_PASS(n) \
	pass { \
		VertexShader = PostProcessVS; \
		PixelShader = PS_UIDetect##n; \
		RenderTarget = texUIDetectMulti##n; \
	} \
	pass { \
		VertexShader = PostProcessVS; \
		PixelShader = PS_UIDetectTimer##n; \
		RenderTarget = texUIDetectTimer##n; \
	}

technique UIDetectSetup < enabled = true; timeout = 1; hidden = true; >
{
	UIDM_TIMER_PASS(1)
	
	#if (UIDM_MASK_COUNT > 1)
		UIDM_TIMER_PASS(2)
	#endif
	
	#if (UIDM_MASK_COUNT > 2)
		UIDM_TIMER_PASS(3)
	#endif
	
	#if (UIDM_MASK_COUNT > 3)
		UIDM_TIMER_PASS(4)
	#endif
	
	#if (UIDM_MASK_COUNT > 4)
		UIDM_TIMER_PASS(5)
	#endif
}

technique UIDetectMulti
{	
	UIDM_DETECT_PASS(1)
	
	#if (UIDM_MASK_COUNT > 1)
		UIDM_DETECT_PASS(2)
	#endif
	
	#if (UIDM_MASK_COUNT > 2)
		UIDM_DETECT_PASS(3)
	#endif
	
	#if (UIDM_MASK_COUNT > 3)
		UIDM_DETECT_PASS(4)
	#endif
	
	#if (UIDM_MASK_COUNT > 4)
		UIDM_DETECT_PASS(5)
	#endif
	
	#if (UIDM_DIAGNOSTICS == 1)
		pass {
			VertexShader = PostProcessVS;
			PixelShader = State_Pixel_Color;
			RenderTarget = textextcolor;
		}
		pass {
			VertexShader = PostProcessVS;
			PixelShader = Fontinvert;
			RenderTarget = textextcolor2;
		}
		pass {
			VertexShader = PostProcessVS;
			PixelShader = FontTransparancy;
		}
		pass {
			VertexShader = PostProcessVS;
			PixelShader = Crosshair;
		}
		pass {
			VertexShader = PostProcessVS;
			PixelShader = PS_StoreColor;
			RenderTarget = texColorOrigMulti;
		}
	#endif
}

technique UIDetectMulti_Before {
    pass {
        VertexShader = PostProcessVS;
        PixelShader = PS_StoreColor;
        RenderTarget = texColorBeforeMulti;
    }
	#if (UIDM_ANTIBLOOM == 1)
		pass {
			VertexShader = PostProcessVS;
			PixelShader = PS_Antibloom;
		}
	#endif
}

technique UIDetectMulti_After
{
	pass {
		VertexShader = PostProcessVS;
		PixelShader = PS_RestoreColor;
	}
	#if (UIDM_DIAGNOSTICS == 1)
		pass {
			VertexShader = PostProcessVS;
			PixelShader = PS_ShowOrigColor;
		}
	#endif
}
