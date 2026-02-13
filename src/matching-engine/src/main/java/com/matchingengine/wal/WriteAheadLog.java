package com.matchingengine.wal;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.MappedByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Write-Ahead Log using a memory-mapped file.
 *
 * Records are length-prefixed: 4-byte int (big-endian) followed by the data bytes.
 * The flush() method calls MappedByteBuffer.force() to sync to disk,
 * and is deferred to endOfBatch events from the Disruptor for amortized I/O.
 *
 * For this experiment, the WAL is append-only with no rotation or compaction.
 * A 64 MB file is sufficient for a 30-minute experiment run.
 */
public class WriteAheadLog {

    private static final Logger logger = LoggerFactory.getLogger(WriteAheadLog.class);

    private final MappedByteBuffer buffer;
    private final RandomAccessFile raf;
    private final int capacity;
    private int position;
    private boolean full;

    public WriteAheadLog(String path, int sizeMb) throws IOException {
        this.capacity = sizeMb * 1024 * 1024;
        this.position = 0;
        this.full = false;

        // Ensure directory exists
        Path dirPath = Path.of(path);
        Files.createDirectories(dirPath);

        Path filePath = dirPath.resolve("wal.dat");
        logger.info("Initializing WAL at {} with size {} MB", filePath, sizeMb);

        this.raf = new RandomAccessFile(filePath.toFile(), "rw");
        this.raf.setLength(capacity);
        FileChannel channel = this.raf.getChannel();
        this.buffer = channel.map(FileChannel.MapMode.READ_WRITE, 0, capacity);

        // We keep the channel and RAF open for the lifetime of the process.
        // The MappedByteBuffer remains valid even after channel close, but
        // we do not close them here to avoid potential issues.
    }

    /**
     * Append a length-prefixed record to the WAL.
     * Does NOT call force() -- that is deferred to flush().
     *
     * Record format: [4-byte length][data bytes]
     */
    public void append(byte[] data) {
        if (full) {
            return;
        }

        int recordSize = 4 + data.length;
        if (position + recordSize > capacity) {
            logger.warn("WAL is full. Position: {}, capacity: {}, record size: {}. "
                    + "Stopping WAL appends.", position, capacity, recordSize);
            full = true;
            return;
        }

        buffer.putInt(position, data.length);
        position += 4;

        buffer.position(position);
        buffer.put(data, 0, data.length);
        position += data.length;
    }

    /**
     * Force the memory-mapped buffer to sync to disk.
     * This is the expensive operation -- called on endOfBatch to amortize cost.
     */
    public void flush() {
        if (buffer != null) {
            buffer.force();
        }
    }

    /**
     * Flush and release resources.
     */
    public void close() {
        flush();
        try {
            raf.close();
        } catch (IOException e) {
            logger.warn("Failed to close WAL RandomAccessFile: {}", e.getMessage());
        }
        logger.info("WAL closed. Final position: {} bytes written", position);
        // MappedByteBuffer does not have an explicit unmap in standard Java.
        // The buffer will be unmapped when GC collects it.
    }

    public int getPosition() {
        return position;
    }

    public int getCapacity() {
        return capacity;
    }

    public boolean isFull() {
        return full;
    }
}
