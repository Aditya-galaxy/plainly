package com.kronagent.plainly

import android.graphics.Bitmap
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import kotlinx.coroutines.tasks.await

/** On-device OCR with ML Kit; the table is rebuilt from the lines' corner points by rowsFromLines (Core.kt). */
object Reader {
    suspend fun ocrRows(bitmap: Bitmap): List<String> {
        val result = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS).process(InputImage.fromBitmap(bitmap, 0)).await()
        val lines = result.textBlocks.flatMap { it.lines }.mapNotNull { l ->
            val pts = l.cornerPoints ?: return@mapNotNull null
            if (pts.size != 4) null else OcrLine(l.text, pts.map { it.x.toDouble() to it.y.toDouble() })
        }
        return rowsFromLines(lines)
    }
}
