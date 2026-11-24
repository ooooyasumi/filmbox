package com.filmbox.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class IndexCheckpointTest {
    @Test
    fun interruptedDirectoryWalkResumesWithoutLosingFilesOrRepeatingCompletedFolders() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val name = "checkpoint-qa-${System.nanoTime()}.db"
        val library = Library("qa", "测试", "", account = "account", folderId = "root", path = "/")
        var store = CloudIndexStore(context, name)
        try {
            store.begin(library, true)
            val root = store.next(library.id)!!
            val media = Media("qa:one", library.id, "", "one.jpg", "image/jpeg", remoteId = "one")
            val child = CloudFolder("child", "子目录", "/子目录")
            store.save(library.id, root, listOf(media), listOf(child))
            assertEquals(IndexProgress(1, 1, 1), store.progress(library.id))
            store.close()
            store = CloudIndexStore(context, name)
            store.begin(library, true)
            assertEquals(child, store.next(library.id))
            assertEquals(listOf(media), store.entries(library.id))
            store.save(
                library.id,
                child,
                listOf(media.copy(id = "qa:two", name = "two.jpg", remoteId = "two")),
                emptyList(),
            )
            assertNull(store.next(library.id))
            assertEquals(IndexProgress(2, 2, 0), store.progress(library.id))
            // Changing the source or hidden-file policy invalidates the incomplete snapshot.
            store.begin(library, false)
            assertEquals("root", store.next(library.id)!!.id)
            assertTrue(store.entries(library.id).isEmpty())
            store.clear(library.id)
            assertEquals(IndexProgress(0, 0, 0), store.progress(library.id))
        } finally {
            store.close()
            context.deleteDatabase(name)
        }
    }
}
