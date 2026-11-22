package com.kronagent.plainly

import android.graphics.Bitmap
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import kotlinx.coroutines.tasks.await
import kotlin.math.cos
import kotlin.math.sin

/**
 * On-device OCR with ML Kit, then the printed table is rebuilt into one string per row.
 * Photos are rarely straight, so each line's centre is rotated by the average text angle ML Kit reports
 * before lines are grouped into rows; otherwise a 2° tilt splits one table row across two.
 */
object Reader {
    suspend fun ocrRows(bitmap: Bitmap): List<String> {
        val result = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS).process(InputImage.fromBitmap(bitmap, 0)).await()
        val lines = result.textBlocks.flatMap { it.lines }.filter { it.boundingBox != null && it.text.isNotBlank() }
        if (lines.isEmpty()) return emptyList()
        val angle = Math.toRadians(lines.map { it.angle.toDouble() }.sorted()[lines.size / 2]) // median: robust to stray stamps
        data class Item(val x: Double, val y: Double, val h: Double, val text: String)
        val items = lines.map { l ->
            val b = l.boundingBox!!
            val cx = b.exactCenterX().toDouble()
            val cy = b.exactCenterY().toDouble()
            // Undo the page tilt so every cell of a row lands on (almost) the same y.
            Item(cx * cos(-angle) - cy * sin(-angle), cx * sin(-angle) + cy * cos(-angle), b.height().toDouble(), l.text.trim())
        }.sortedBy { it.y }
        val rows = mutableListOf<MutableList<Item>>()
        for (it in items) {
            val row = rows.lastOrNull()
            if (row != null && kotlin.math.abs(row.map { r -> r.y }.average() - it.y) < it.h * 0.6) row += it else rows += mutableListOf(it)
        }
        return rows.map { r -> r.sortedBy { it.x }.joinToString(" ") { it.text } }
    }
}
