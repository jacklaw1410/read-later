// Generated from design/tokens.json by tools/tokens (readlater-tokens). Do not edit.
package app.readlater.design

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp

/** Semantic colours. The component layer is Compose; these are layer 2. */
interface ReadLaterTokens {
    val pagePaper: Color, val pageSurface: Color, val pageRaised: Color, val textBody: Color, val textMeta: Color, val lineHair: Color, val brandLink: Color, val actionFill: Color, val actionInk: Color, val ghostFill: Color, val washFill: Color, val washInk: Color, val rulePaused: Color, val ruleRing: Color, val markSelected: Color, val markSaved: Color, val markSavedFill: Color, val skipSurface: Color, val skipBorder: Color, val skipInk: Color, val chipSurface: Color, val chipInk: Color, val chipBorder: Color, val codeInlineSurface: Color, val markCoincide: Color, val veilScrim: Color, val holdSurface: Color, val holdInk: Color, val holdBorder: Color
}

object LightTokens : ReadLaterTokens {
    override val pagePaper = Color(0xFFFFFCF7)
    override val pageSurface = Color(0xFFFFFFFF)
    override val pageRaised = Color(0xFFFFF7ED)
    override val textBody = Color(0xFF191C1F)
    override val textMeta = Color(0xFF5B6570)
    override val lineHair = Color(0xFFE7E0D9)
    override val brandLink = Color(0xFF334E68)
    override val actionFill = Color(0xFF334E68)
    override val actionInk = Color(0xFFFFFFFF)
    override val ghostFill = Color(0xFFFFFFFF)
    override val washFill = Color(0xFFFDE68A)
    override val washInk = Color(0xFF78350F)
    override val rulePaused = Color(0xFFE8D9B0)
    override val ruleRing = Color(0xFF8A6D1B)
    override val markSelected = Color(0xFFDCE9F5)
    override val markSaved = Color(0xFF9A3412)
    override val markSavedFill = Color(0xFFFFF0E6)
    override val skipSurface = Color(0xFFF7F3EC)
    override val skipBorder = Color(0xFFE7E0D9)
    override val skipInk = Color(0xFF191C1F)
    override val chipSurface = Color(0xFFEFE7D3)
    override val chipInk = Color(0xFF7A6A3A)
    override val chipBorder = Color(0xFFE0D3B0)
    override val codeInlineSurface = Color(0xFFF1EDE4)
    override val markCoincide = Color(0xFFB45309)
    override val veilScrim = Color(0xFF191C1F).copy(alpha = 0.28f)
    override val holdSurface = Color(0xFFFFF0E6)
    override val holdInk = Color(0xFF9A3412)
    override val holdBorder = Color(0xFFFDBA74)
}

object DarkTokens : ReadLaterTokens {
    override val pagePaper = Color(0xFF121417)
    override val pageSurface = Color(0xFF1E2226)
    override val pageRaised = Color(0xFF262B31)
    override val textBody = Color(0xFFE8E6E1)
    override val textMeta = Color(0xFFA8B0B8)
    override val lineHair = Color(0xFF333A42)
    override val brandLink = Color(0xFF7FB3D5)
    override val actionFill = Color(0xFF2C4A63)
    override val actionInk = Color(0xFFFFFFFF)
    override val ghostFill = Color(0xFF242A30)
    override val washFill = Color(0xFF854D0E)
    override val washInk = Color(0xFFFDE68A)
    override val rulePaused = Color(0xFF4A4030)
    override val ruleRing = Color(0xFFC9A94E)
    override val markSelected = Color(0xFF2C4A66)
    override val markSaved = Color(0xFFFDBA74)
    override val markSavedFill = Color(0xFF3A2A1F)
    override val skipSurface = Color(0xFF1B1F24)
    override val skipBorder = Color(0xFF2C333A)
    override val skipInk = Color(0xFFC9CDD2)
    override val chipSurface = Color(0xFF2E2A20)
    override val chipInk = Color(0xFFD8C48C)
    override val chipBorder = Color(0xFF453D2A)
    override val codeInlineSurface = Color(0xFF23282E)
    override val markCoincide = Color(0xFFF59E0B)
    override val veilScrim = Color(0xFF000000).copy(alpha = 0.28f)
    override val holdSurface = Color(0xFF3A2A1F)
    override val holdInk = Color(0xFFFDBA74)
    override val holdBorder = Color(0xFF7C4A1E)
}

@Composable
@ReadOnlyComposable
fun tokens(): ReadLaterTokens = if (isSystemInDarkTheme()) DarkTokens else LightTokens

/** Layer 2 sizes. Android scales these with sp where text is involved. */
object Space {
    val inlineGap = 4.dp
    val controlGap = 8.dp
    val stackGap = 12.dp
    val paragraphGap = 16.dp
    val screenGutter = 20.dp
    val breathingRoom = 32.dp
    val chipRadius = 4.dp
    val innerRadius = 8.dp
    val buttonRadius = 10.dp
    val cardRadius = 12.dp
    // provisional: sheet
    val sheetRadius = 16.dp
    val pillRadius = 999.dp
    val minTarget = 44.dp
    val maxLineWidth = 640.dp
    val playerBar = 58.dp
    val chrome = 44.dp
}

/** Layer 2 type sizes. Compose builds its own TextStyle from these. */
object TypeScale {
    val bodySize = 19.sp
    val bodyLine = 31.sp
    val titleSize = 28.sp
    val titleLine = 34.sp
    val headingSize = 22.sp
    val captionSize = 13.sp
    val playerSize = 15.sp
    val lookupWordSize = 22.sp
    val glossSize = 17.sp
    val offerTitleSize = 15.sp
    val chipSize = 10.sp
    /** Tracking in em: multiply by the size. */
    val chipTracking = 0.088.em
    val eyebrowSize = 11.sp
    /** Tracking in em: multiply by the size. */
    val eyebrowTracking = 0.08.em
    val codeSize = 12.sp
    val noteSize = 14.sp
    val monoSize = 11.sp
    val iconSize = 20.sp
}

/** Layer 2 motion: milliseconds plus the curve, not its name. */
object Motion {
    const val wash = 150L
    val washEasing = LinearEasing
    const val sheet = 180L
    val sheetEasing = CubicBezierEasing(0.42f, 0f, 0.58f, 1f)
    const val screen = 180L
    val screenEasing = CubicBezierEasing(0.42f, 0f, 0.58f, 1f)
    const val entryProgress = 300L
    val entryProgressEasing = CubicBezierEasing(0.42f, 0f, 0.58f, 1f)
}
