package com.gwitko.conduit

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF

/**
 * A widget limit ring as a bitmap, so it takes the app theme's colours on
 * every Android version (RemoteViews cannot tint a progress drawable before
 * Android 12): a [track] circle and the used share in [color] from 12
 * o'clock.
 */
object RingBitmap {
    fun create(percent: Int, track: Int, color: Int, sizePx: Int): Bitmap {
        val size = sizePx.coerceIn(16, 256)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val stroke = size * 0.11f
        val inset = stroke / 2 + 1f
        val rect = RectF(inset, inset, size - inset, size - inset)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = stroke
            this.color = track
        }
        canvas.drawArc(rect, 0f, 360f, false, paint)
        if (percent > 0) {
            paint.color = color
            paint.strokeCap = Paint.Cap.ROUND
            canvas.drawArc(rect, -90f, 360f * percent.coerceIn(0, 100) / 100f, false, paint)
        }
        return bitmap
    }
}
