package com.example.migration;

import org.apache.flink.configuration.Configuration;
import org.apache.flink.streaming.api.functions.source.RichParallelSourceFunction;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.sql.*;
import java.util.*;
import java.util.concurrent.TimeUnit;

/**
 * Parallel source function that reads data from TDengine with native connector using direct connections
 * This implementation uses direct database connections instead of a connection pool:
 * 1. Each task creates its own direct connection to TDengine
 * 2. Uses TDengine native connector instead of REST API
 * 3. Implements LIMIT/OFFSET-based pagination instead of cursor-based pagination
 * 4. Properly manages database resources with try-with-resources
 * 5. Optimizes time partitioning for more balanced data distribution
 */
public class ParallelTDengineNativeSourceFunctionWithDirectConnection_OFFSET extends RichParallelSourceFunction<List<Map<String, Object>>> {
    private static final long serialVersionUID = 1L;
    private static final Logger LOG = LoggerFactory.getLogger(ParallelTDengineNativeSourceFunctionWithDirectConnection_OFFSET.class);
    
    // Running flag
    private volatile boolean isRunning = true;
    
    // Database connection parameters
    private final String jdbcUrl;
    private final String username;
    private final String password;
    private final String tableName;
    private final int batchSize;
    
    // Time range parameters
    private final String startTime;
    private final String endTime;
    
    // Retry parameters
    private static final int MAX_RETRIES = 5;
    private static final int RETRY_DELAY_MS = 15000; // 15 seconds
    
    static {
        // Load TDengine native driver
        try {
            // Register the JDBC driver
            Class.forName("com.taosdata.jdbc.TSDBDriver");
            LOG.info("TDengine JDBC driver registered successfully");
        } catch (ClassNotFoundException e) {
            LOG.error("Failed to register TDengine JDBC driver: {}", e.getMessage());
            throw new RuntimeException("Failed to register TDengine JDBC driver", e);
        }
    }
    
    /**
     * Constructor with database connection parameters
     */
    public ParallelTDengineNativeSourceFunctionWithDirectConnection_OFFSET(String jdbcUrl, String username, String password, 
                                                 String tableName, int batchSize) {
        this(jdbcUrl, username, password, tableName, batchSize, null, null);
    }
    
    /**
     * Constructor with database connection parameters and time range
     */
    public ParallelTDengineNativeSourceFunctionWithDirectConnection_OFFSET(String jdbcUrl, String username, String password, String tableName, 
                                                 int batchSize, String startTime, String endTime) {
        this.jdbcUrl = jdbcUrl;
        this.username = username;
        this.password = password;
        this.tableName = tableName;
        this.batchSize = batchSize;
        this.startTime = startTime;
        this.endTime = endTime;
    }
    
    @Override
    public void open(Configuration parameters) throws Exception {
        super.open(parameters);
        
        int subtaskIndex = getRuntimeContext().getIndexOfThisSubtask();
        int parallelism = getRuntimeContext().getNumberOfParallelSubtasks();
        
        // Test database connection
        try (Connection conn = createConnection()) {
            LOG.info("Subtask {} successfully connected to TDengine using direct connection", subtaskIndex);
        } catch (SQLException e) {
            LOG.error("Subtask {} failed to connect to TDengine: {}", subtaskIndex, e.getMessage());
            throw e;
        }
    }
    
    /**
     * Create a direct connection to TDengine
     */
    private Connection createConnection() throws SQLException {
        int retries = 0;
        SQLException lastException = null;
        
        while (retries < MAX_RETRIES) {
            try {
                LOG.debug("Creating direct connection to TDengine (attempt {}/{})", retries + 1, MAX_RETRIES);
                Connection conn = DriverManager.getConnection(jdbcUrl, username, password);
                
                // Test the connection
                try (Statement stmt = conn.createStatement();
                     ResultSet rs = stmt.executeQuery("SELECT SERVER_STATUS()")) {
                    if (rs.next()) {
                        LOG.debug("TDengine connection test successful");
                    }
                }
                
                return conn;
            } catch (SQLException e) {
                lastException = e;
                retries++;
                LOG.warn("Failed to connect to TDengine (attempt {}/{}): {}", 
                        retries, MAX_RETRIES, e.getMessage());
                
                if (retries < MAX_RETRIES) {
                    try {
                        LOG.info("Waiting {} ms before next connection attempt", RETRY_DELAY_MS);
                        Thread.sleep(RETRY_DELAY_MS);
                    } catch (InterruptedException ie) {
                        Thread.currentThread().interrupt();
                        throw new SQLException("Connection retry interrupted", ie);
                    }
                }
            }
        }
        
        LOG.error("Failed to connect to TDengine after {} attempts", MAX_RETRIES);
        throw lastException;
    }
    
    @Override
    public void run(SourceContext<List<Map<String, Object>>> ctx) throws Exception {
        // Get parallelism information
        int parallelism = getRuntimeContext().getNumberOfParallelSubtasks();
        int subtaskIndex = getRuntimeContext().getIndexOfThisSubtask();
        
        LOG.info("Native source subtask {}/{} starting", subtaskIndex + 1, parallelism);
        
        // Get time range for partitioning
        Timestamp[] timeRange = getTimeRange();
        if (timeRange == null || timeRange.length != 2) {
            LOG.error("Failed to get time range for partitioning");
            return;
        }
        
        Timestamp startTime = timeRange[0];
        Timestamp endTime = timeRange[1];
        
        LOG.info("Time range for migration: {} to {}", startTime, endTime);
        
        // Calculate time partitions for this subtask
        List<TimePartition> timePartitions = createTimePartitions(startTime, endTime, parallelism);
        TimePartition myPartition = timePartitions.get(subtaskIndex);
        
        LOG.info("Subtask {} assigned time partition: {} to {}", 
                subtaskIndex, myPartition.startTime, myPartition.endTime);
        
        // Process data in the assigned time partition
        processTimePartition(myPartition, ctx);
    }
    
    /**
     * Process data in the assigned time partition using LIMIT/OFFSET pagination
     * @param partition Time partition to process
     * @param ctx Source context for emitting data
     */
    private void processTimePartition(TimePartition partition, SourceContext<List<Map<String, Object>>> ctx) throws Exception {
        long offset = 0;
        boolean hasMoreData = true;
        long processedRecords = 0;
        long logThreshold = batchSize * 10; // Log every 10 batches
        
        while (isRunning && hasMoreData) {
            try {
                // Fetch batch using LIMIT/OFFSET pagination
                List<Map<String, Object>> batch = fetchBatchByTimeRangeWithOffset(
                        partition.startTime, partition.endTime, batchSize, offset);
                
                if (batch.isEmpty()) {
                    LOG.info("No more data in time partition {} to {}. Finishing source.", 
                            partition.startTime, partition.endTime);
                    hasMoreData = false;
                    break;
                }
                
                // Emit the batch with checkpoint lock
                synchronized (ctx.getCheckpointLock()) {
                    ctx.collect(batch);
                }
                
                // Update offset for next batch
                offset += batch.size();
                
                // Update processed records count
                processedRecords += batch.size();
                
                // Log progress periodically to avoid excessive logging
                if (processedRecords % logThreshold == 0) {
                    LOG.info("Processed {} records from time partition {} to {}", 
                            processedRecords, partition.startTime, partition.endTime);
                }
                
                // Add a small delay to prevent overwhelming the source
                Thread.sleep(100);
            } catch (SQLException e) {
                LOG.error("Error fetching data from TDengine: {}", e.getMessage());
                // Continue to next iteration, which will retry the operation
            }
        }
        
        // Log completion information once at the end
        LOG.info("Completed processing time partition {} to {}, total records: {}", 
                partition.startTime, partition.endTime, processedRecords);
    }
    
    /**
     * Fetch a batch of data from TDengine using LIMIT/OFFSET pagination
     * @param startTime Start time of the partition
     * @param endTime End time of the partition
     * @param batchSize Number of records to fetch
     * @param offset Offset for pagination
     * @return List of records as maps
     */
    private List<Map<String, Object>> fetchBatchByTimeRangeWithOffset(Timestamp startTime, Timestamp endTime, 
                                                      int batchSize, long offset) throws SQLException {
        List<Map<String, Object>> batch = new ArrayList<>();
        int retries = 0;
        SQLException lastException = null;
        
        while (retries < MAX_RETRIES) {
            // Use LIMIT/OFFSET syntax for pagination
            String sql = "SELECT * FROM " + tableName + " WHERE ts >= ? AND ts < ? ORDER BY ts LIMIT ? OFFSET ?";
            
            try (Connection conn = createConnection();
                 PreparedStatement pstmt = conn.prepareStatement(sql)) {
                
                pstmt.setTimestamp(1, startTime);
                pstmt.setTimestamp(2, endTime);
                pstmt.setInt(3, batchSize);
                pstmt.setLong(4, offset);
                
                // Set fetch size to improve JDBC performance
                pstmt.setFetchSize(batchSize);
                
                try (ResultSet rs = pstmt.executeQuery()) {
                    ResultSetMetaData metaData = rs.getMetaData();
                    int columnCount = metaData.getColumnCount();
                    
                    while (rs.next()) {
                        Map<String, Object> row = new HashMap<>();
                        for (int i = 1; i <= columnCount; i++) {
                            String columnName = metaData.getColumnName(i);
                            Object value = rs.getObject(i);
                            row.put(columnName, value);
                        }
                        batch.add(row);
                    }
                }
                
                return batch;
            } catch (SQLException e) {
                lastException = e;
                retries++;
                LOG.warn("Failed to fetch batch by time range with offset (attempt {}/{}): {}", 
                        retries, MAX_RETRIES, e.getMessage());
                
                if (retries < MAX_RETRIES) {
                    try {
                        LOG.info("Waiting {} ms before retry", RETRY_DELAY_MS);
                        Thread.sleep(RETRY_DELAY_MS);
                    } catch (InterruptedException ie) {
                        Thread.currentThread().interrupt();
                        throw new SQLException("Operation interrupted", ie);
                    }
                }
            }
        }
        
        LOG.error("Failed to fetch batch by time range with offset after {} attempts", MAX_RETRIES);
        throw lastException;
    }
    
    private Timestamp[] getTimeRange() throws SQLException {
        int retries = 0;
        SQLException lastException = null;
        
        while (retries < MAX_RETRIES) {
            try (Connection conn = createConnection()) {
                // If both start and end time are provided, use them directly
                if (startTime != null && endTime != null) {
                    try {
                        Timestamp start = Timestamp.valueOf(startTime);
                        Timestamp end = Timestamp.valueOf(endTime);
                        LOG.info("Using user-specified time range: {} to {}", start, end);
                        return new Timestamp[] { start, end };
                    } catch (IllegalArgumentException e) {
                        LOG.warn("Invalid time format. Expected format: yyyy-MM-dd HH:mm:ss.SSS. Falling back to querying time range from database.");
                        // Continue to query from database
                    }
                }
                
                // Build the query based on provided time constraints
                StringBuilder queryBuilder = new StringBuilder("SELECT ");
                
                if (startTime != null) {
                    queryBuilder.append("MIN(ts) AS min_ts FROM ").append(tableName)
                               .append(" WHERE ts >= '").append(startTime).append("'");
                    
                    if (endTime != null) {
                        queryBuilder.append(" AND ts < '").append(endTime).append("'");
                    }
                } else if (endTime != null) {
                    queryBuilder.append("MIN(ts) AS min_ts FROM ").append(tableName)
                               .append(" WHERE ts < '").append(endTime).append("'");
                } else {
                    queryBuilder.append("FIRST(ts), LAST(ts) FROM ").append(tableName);
                }
                
                String query = queryBuilder.toString();
                LOG.info("Executing time range query: {}", query);
                
                try (Statement stmt = conn.createStatement();
                     ResultSet rs = stmt.executeQuery(query)) {
                    
                    if (rs.next()) {
                        Timestamp minTs, maxTs;
                        
                        if (startTime != null || endTime != null) {
                            minTs = rs.getTimestamp("min_ts");
                            
                            // If we have a start time constraint, use it
                            if (startTime != null) {
                                try {
                                    Timestamp constraintStart = Timestamp.valueOf(startTime);
                                    if (minTs == null || constraintStart.after(minTs)) {
                                        minTs = constraintStart;
                                    }
                                } catch (IllegalArgumentException e) {
                                    LOG.warn("Invalid start time format: {}", startTime);
                                }
                            }
                            
                            // For max timestamp, we need another query
                            String maxQuery;
                            if (startTime != null && endTime != null) {
                                maxQuery = "SELECT MAX(ts) AS max_ts FROM " + tableName + 
                                           " WHERE ts >= '" + startTime + "' AND ts < '" + endTime + "'";
                            } else if (startTime != null) {
                                maxQuery = "SELECT MAX(ts) AS max_ts FROM " + tableName + 
                                           " WHERE ts >= '" + startTime + "'";
                            } else {
                                maxQuery = "SELECT MAX(ts) AS max_ts FROM " + tableName + 
                                           " WHERE ts < '" + endTime + "'";
                            }
                            
                            try (Statement maxStmt = conn.createStatement();
                                 ResultSet maxRs = maxStmt.executeQuery(maxQuery)) {
                                
                                if (maxRs.next()) {
                                    maxTs = maxRs.getTimestamp("max_ts");
                                    
                                    // If we have an end time constraint, use it
                                    if (endTime != null) {
                                        try {
                                            Timestamp constraintEnd = Timestamp.valueOf(endTime);
                                            if (maxTs == null || constraintEnd.before(maxTs)) {
                                                maxTs = constraintEnd;
                                            }
                                        } catch (IllegalArgumentException e) {
                                            LOG.warn("Invalid end time format: {}", endTime);
                                        }
                                    }
                                } else {
                                    LOG.error("Failed to get max timestamp");
                                    return null;
                                }
                            }
                        } else {
                            // Using FIRST/LAST query
                            minTs = rs.getTimestamp(1);
                            maxTs = rs.getTimestamp(2);
                        }
                        
                        if (minTs != null && maxTs != null) {
                            LOG.info("Time range from database: {} to {}", minTs, maxTs);
                            return new Timestamp[] { minTs, maxTs };
                        } else {
                            LOG.error("Invalid time range: min={}, max={}", minTs, maxTs);
                            return null;
                        }
                    } else {
                        LOG.error("No data found in table {}", tableName);
                        return null;
                    }
                }
            } catch (SQLException e) {
                lastException = e;
                retries++;
                LOG.warn("Failed to get time range (attempt {}/{}): {}", 
                        retries, MAX_RETRIES, e.getMessage());
                
                if (retries < MAX_RETRIES) {
                    try {
                        LOG.info("Waiting {} ms before retry", RETRY_DELAY_MS);
                        Thread.sleep(RETRY_DELAY_MS);
                    } catch (InterruptedException ie) {
                        Thread.currentThread().interrupt();
                        throw new SQLException("Operation interrupted", ie);
                    }
                }
            }
        }
        
        LOG.error("Failed to get time range after {} attempts", MAX_RETRIES);
        throw lastException;
    }
    
    private List<TimePartition> createTimePartitions(Timestamp startTime, Timestamp endTime, int numPartitions) {
        List<TimePartition> partitions = new ArrayList<>();
        
        long startMillis = startTime.getTime();
        long endMillis = endTime.getTime();
        long rangeMillis = endMillis - startMillis;
        long partitionMillis = rangeMillis / numPartitions;
        
        for (int i = 0; i < numPartitions; i++) {
            long partitionStartMillis = startMillis + (i * partitionMillis);
            // For the last partition, use the exact endMillis to ensure we include all data
            // For other partitions, use the start of the next partition as the exclusive end
            long partitionEndMillis = (i == numPartitions - 1) ? 
                    endMillis : (startMillis + ((i + 1) * partitionMillis));
            
            Timestamp partitionStart = new Timestamp(partitionStartMillis);
            Timestamp partitionEnd = new Timestamp(partitionEndMillis);
            
            partitions.add(new TimePartition(partitionStart, partitionEnd));
        }
        
        return partitions;
    }
    
    @Override
    public void cancel() {
        isRunning = false;
    }
    
    // Helper class to represent a time partition
    public static class TimePartition {
        final Timestamp startTime;
        final Timestamp endTime;
        
        TimePartition(Timestamp startTime, Timestamp endTime) {
            this.startTime = startTime;
            this.endTime = endTime;
        }
    }
}
