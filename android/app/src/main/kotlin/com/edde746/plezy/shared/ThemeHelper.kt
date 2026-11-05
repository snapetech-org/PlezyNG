package com.edde746.plezy.shared

import android.graphics.Color

object ThemeHelper {
  fun themeColor(mode: String?): Int? = when (mode) {
    "oled" -> Color.BLACK
    "dark" -> Color.parseColor("#0B1118")
    "light" -> Color.parseColor("#F4F7F9")
    else -> null
  }
}
