package com.example.migration;

import com.influxdb.client.InfluxDBClient;
import com.influxdb.client.InfluxDBClientFactory;
import com.influxdb.client.WriteApi;
import com.influxdb.client.WriteOptions;
import com.influxdb.client.domain.WritePrecision;
import com.influxdb.client.write.Point;
import org.apache.flink.api.common.functions.FlatMapFunction;
import org.apache.flink.api.common.restartstrategy.RestartStrategies;
import org.apache.flink.api.common.time.Time;
import org.apache.flink.configuration.Configuration;
import org.apache.flink.runtime.state.filesystem.FsStateBackend;
import org.apache.flink.streaming.api.CheckpointingMode;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.CheckpointConfig;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.streaming.api.functions.sink.RichSinkFunction;
import org.apache.flink.util.Collector;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.sql.*;
import java.util.*;
import java.util.concurrent.TimeUnit;

/**
 * TDengine to InfluxDB Native Direct Connection Migration with OFFSET-based pagination
 * 
 * This Flink application migrates data from TDengine to InfluxDB using direct database connections
 * with the TDengine native connector for improved performance and OFFSET-based pagination for data consistency.
 * 
 * Key features:
 * - Uses TDengine native connector instead of REST API
 * - Direct database connections instead of connection pooling
 * - LIMIT/OFFSET-based pagination instead of cursor-based pagination to prevent data loss
 * - Reduced parallelism to avoid overwhelming TDengine
 * - Proper resource management with try-with-resources
 * - Smaller batch sizes to reduce memory pressure
 */
public class TDengineToInfluxDBNativeDirectMigration_OFFSET {
    private static final Logger LOG = LoggerFactory.getLogger(TDengineToInfluxDBNativeDirectMigration_OFFSET.class);
    
    // Default values - reduced for better stability
    private static final int DEFAULT_BATCH_SIZE = 2000; // Smaller batch size
    private static final int DEFAULT_PARALLELISM = 8;   // Reduced parallelism
    private static final int DEFAULT_CHECKPOINT_INTERVAL = 30000;
    
    // Database connection parameters
    private static String sourceJdbcUrl;
    private static String sourceUsername;
    private static String sourcePassword;
    private static String sourceTable;
    
    private static String targetInfluxUrl;
    private static String targetToken;
    private static String targetOrg;
    private static String targetBucket;
    private static String targetMeasurement;
    
    // Configuration parameters
    private static int batchSize;
    private static int parallelism;
    
    // Time range parameters (optional)
    private static String startTime = null;
    private static String endTime = null;

    static {
        // Load TDengine native driver
        try {
            System.loadLibrary("taos");
            LOG.info("TDengine native library loaded successfully");
        } catch (UnsatisfiedLinkError e) {
            LOG.error("Failed to load TDengine native library: {}", e.getMessage());
            LOG.error("Make sure the TDengine client is installed and LD_LIBRARY_PATH includes /usr/local/taos/driver");
            throw new RuntimeException("Failed to load TDengine native library", e);
        }
    }

    public static void main(String[] args) throws Exception {
        // Parse command line arguments
        parseArguments(args);
        
        // Set up the execution environment with checkpointing
        final StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        
        // Configure checkpointing
        env.enableCheckpointing(DEFAULT_CHECKPOINT_INTERVAL);
        env.getCheckpointConfig().setCheckpointingMode(CheckpointingMode.EXACTLY_ONCE);
        env.getCheckpointConfig().setMinPauseBetweenCheckpoints(10000);
        env.getCheckpointConfig().setCheckpointTimeout(120000);
        env.getCheckpointConfig().setMaxConcurrentCheckpoints(1);
        env.getCheckpointConfig().setExternalizedCheckpointCleanup(
                CheckpointConfig.ExternalizedCheckpointCleanup.RETAIN_ON_CANCELLATION);
        
        // Set state backend to filesystem for durability
        env.setStateBackend(new FsStateBackend("hdfs:///flink-checkpoints"));
        
        // Configure restart strategy
        env.setRestartStrategy(RestartStrategies.fixedDelayRestart(
                3, // number of restart attempts
                Time.of(10, TimeUnit.SECONDS) // delay between attempts
        ));
        
        // Set global parallelism from command line argument
        env.setParallelism(parallelism);
        
        // Log the migration parameters
        LOG.info("Starting native direct connection migration with OFFSET pagination from {} table {} to InfluxDB measurement {}", 
                sourceJdbcUrl, sourceTable, targetMeasurement);
        LOG.info("Using parallelism: {}, batch size: {}", parallelism, batchSize);
        
        // Convert JDBC URL from REST API format to native format if needed
        String nativeJdbcUrl = convertToNativeJdbcUrl(sourceJdbcUrl);
        LOG.info("Using native JDBC URL: {}", nativeJdbcUrl);
        
        // Create a DataStream from TDengine source with native connector, direct connections and OFFSET pagination
        DataStream<List<Map<String, Object>>> tdengineSource = env
                .addSource(new ParallelTDengineNativeSourceFunctionWithDirectConnection_OFFSET(
                        nativeJdbcUrl, sourceUsername, sourcePassword, sourceTable, batchSize, startTime, endTime))
                .name("TDengine-Native-DirectConnection-OFFSET-Source");
        
        // Transform the data for InfluxDB
        DataStream<List<Point>> influxPoints = tdengineSource
                .flatMap(new BatchToPointsTransformer(targetMeasurement))
                .name("Transform-To-InfluxDB-Points");
        
        // Write to InfluxDB
        influxPoints
                .addSink(new InfluxDBBulkSinkWithRetry(
                        targetInfluxUrl, targetToken, targetOrg, targetBucket, batchSize))
                .name("InfluxDB-Bulk-Sink");
        
        // Execute the job
        env.execute("TDengine to InfluxDB Native Direct Connection Migration with OFFSET Pagination - " + 
                    sourceTable + " to " + targetMeasurement);
    }
    
    /**
     * Convert REST API JDBC URL to native JDBC URL
     * Example: jdbc:TAOS-RS://hostname:6041/db -> jdbc:TAOS://hostname:6030/db
     */
    private static String convertToNativeJdbcUrl(String jdbcUrl) {
        // If already using native format, return as is
        if (jdbcUrl.startsWith("jdbc:TAOS://")) {
            return jdbcUrl;
        }
        
        // Convert from REST API format to native format
        if (jdbcUrl.startsWith("jdbc:TAOS-RS://")) {
            // Replace protocol and default port
            return jdbcUrl.replace("jdbc:TAOS-RS://", "jdbc:TAOS://").replace(":6041/", ":6030/");
        }
        
        // If unknown format, return as is with warning
        LOG.warn("Unknown JDBC URL format: {}. Expected jdbc:TAOS-RS:// or jdbc:TAOS://", jdbcUrl);
        return jdbcUrl;
    }
    
    /**
     * Parse command line arguments for database connections and configuration
     */
    private static void parseArguments(String[] args) {
        if (args.length < 10) {
            LOG.error("Insufficient arguments provided. Required arguments:");
            LOG.error("1. Source JDBC URL (e.g., jdbc:TAOS://hostname:port/database)");
            LOG.error("2. Source Username");
            LOG.error("3. Source Password");
            LOG.error("4. Source Table");
            LOG.error("5. Target InfluxDB URL");
            LOG.error("6. Target InfluxDB Token");
            LOG.error("7. Target InfluxDB Organization");
            LOG.error("8. Target InfluxDB Bucket");
            LOG.error("9. Target InfluxDB Measurement");
            LOG.error("10. Parallelism (optional, defaults to 8)");
            LOG.error("11. Batch Size (optional, defaults to 2000)");
            LOG.error("12. Start Time (optional, format: yyyy-MM-dd HH:mm:ss.SSS)");
            LOG.error("13. End Time (optional, format: yyyy-MM-dd HH:mm:ss.SSS)");
            throw new IllegalArgumentException("Insufficient arguments provided");
        }
        
        sourceJdbcUrl = args[0];
        sourceUsername = args[1];
        sourcePassword = args[2];
        sourceTable = args[3];
        
        targetInfluxUrl = args[4];
        targetToken = args[5];
        targetOrg = args[6];
        targetBucket = args[7];
        targetMeasurement = args[8];
        
        // Parse optional parameters with defaults
        parallelism = args.length > 9 ? Integer.parseInt(args[9]) : DEFAULT_PARALLELISM;
        batchSize = args.length > 10 ? Integer.parseInt(args[10]) : DEFAULT_BATCH_SIZE;
        
        // Parse optional time range parameters
        if (args.length > 11 && !args[11].isEmpty()) {
            startTime = args[11];
            LOG.info("Using start time: {}", startTime);
        }
        
        if (args.length > 12 && !args[12].isEmpty()) {
            endTime = args[12];
            LOG.info("Using end time: {}", endTime);
        }
        
        // Log the configuration (excluding sensitive information)
        LOG.info("Source JDBC URL: {}", sourceJdbcUrl);
        LOG.info("Source Table: {}", sourceTable);
        LOG.info("Target InfluxDB URL: {}", targetInfluxUrl);
        LOG.info("Target InfluxDB Org: {}", targetOrg);
        LOG.info("Target InfluxDB Bucket: {}", targetBucket);
        LOG.info("Target InfluxDB Measurement: {}", targetMeasurement);
        LOG.info("Parallelism: {}", parallelism);
        LOG.info("Batch Size: {}", batchSize);
    }
    
    /**
     * Transformer that converts TDengine data to InfluxDB points
     */
    public static class BatchToPointsTransformer implements FlatMapFunction<List<Map<String, Object>>, List<Point>> {
        private static final long serialVersionUID = 1L;
        private final String measurementName;
        
        /**
         * Constructor with target measurement name
         */
        public BatchToPointsTransformer(String measurementName) {
            this.measurementName = measurementName;
        }
        
        @Override
        public void flatMap(List<Map<String, Object>> batch, Collector<List<Point>> out) {
            List<Point> points = new ArrayList<>(batch.size());
            
            for (Map<String, Object> row : batch) {
                try {
                    // Extract timestamp
                    Timestamp ts = (Timestamp) row.get("ts");
                    if (ts == null) {
                        LOG.warn("Skipping row with null timestamp");
                        continue;
                    }
                    
                    // Create a point with measurement name
                    Point point = Point.measurement(measurementName)
                            .time(ts.getTime(), WritePrecision.MS);
                    
                    // Process all fields
                    for (Map.Entry<String, Object> entry : row.entrySet()) {
                        String key = entry.getKey();
                        Object value = entry.getValue();
                        
                        // Skip timestamp field
                        if ("ts".equals(key)) {
                            continue;
                        }
                        
                        // If value is null, skip this field
                        if (value == null) {
                            continue;
                        }
                        
                        // Handle numeric fields as measurements
                        if (value instanceof Number) {
                            if (value instanceof Float || value instanceof Double) {
                                point.addField(key, ((Number) value).doubleValue());
                            } else {
                                point.addField(key, ((Number) value).longValue());
                            }
                        } 
                        // Handle non-numeric fields as tags
                        else {
                            // Handle different types of non-numeric fields with explicit encoding
                            try {
                                // Explicit encoding conversion for all string type values
                                if (value instanceof String) {
                                    String strValue = (String)value;
                                    byte[] utf8Bytes = strValue.getBytes("UTF-8");
                                    point.addTag(key, new String(utf8Bytes, "UTF-8"));
                                } else if (value instanceof byte[]) {
                                    // Convert byte array to string using UTF-8 encoding
                                    point.addTag(key, new String((byte[]) value, "UTF-8"));
                                } else {
                                    // For other non-numeric types, convert to string
                                    point.addTag(key, value.toString());
                                }
                            } catch (Exception e) {
                                LOG.warn("Failed to convert field {} to tag, skipping: {}", key, e.getMessage());
                            }
                        }
                    }
                    
                    points.add(point);
                } catch (Exception e) {
                    LOG.error("Error processing row: {}", row, e);
                }
            }
            
            if (!points.isEmpty()) {
                out.collect(points);
            }
        }
    }
    
    /**
     * Sink function that writes data to InfluxDB in bulk with retry logic
     */
    public static class InfluxDBBulkSinkWithRetry extends RichSinkFunction<List<Point>> {
        private static final long serialVersionUID = 1L;
        private transient InfluxDBClient influxDBClient;
        private transient WriteApi writeApi;
        
        // InfluxDB connection parameters
        private final String influxUrl;
        private final String token;
        private final String org;
        private final String bucket;
        private final int batchSize;
        
        // Retry parameters
        private static final int MAX_RETRIES = 5;
        private static final int RETRY_DELAY_MS = 5000;
        
        /**
         * Constructor with InfluxDB connection parameters
         */
        public InfluxDBBulkSinkWithRetry(String influxUrl, String token, String org, String bucket, int batchSize) {
            this.influxUrl = influxUrl;
            this.token = token;
            this.org = org;
            this.bucket = bucket;
            this.batchSize = batchSize;
        }
        
        @Override
        public void open(Configuration parameters) throws Exception {
            super.open(parameters);
            
            // Create InfluxDB client with optimized write options and retry
            connectWithRetry();
        }
        
        private void connectWithRetry() throws Exception {
            int retries = 0;
            Exception lastException = null;
            boolean connected = false;
            
            while (!connected && retries < MAX_RETRIES) {
                try {
                    // Close previous connections if they exist
                    if (writeApi != null) {
                        try {
                            writeApi.close();
                        } catch (Exception e) {
                            LOG.warn("Error closing previous WriteApi", e);
                        }
                    }
                    
                    if (influxDBClient != null) {
                        try {
                            influxDBClient.close();
                        } catch (Exception e) {
                            LOG.warn("Error closing previous InfluxDBClient", e);
                        }
                    }
                    
                    LOG.info("Attempting to connect to InfluxDB (attempt {}/{})", retries + 1, MAX_RETRIES);
                    
                    // Create optimized write options
                    WriteOptions writeOptions = WriteOptions.builder()
                            .batchSize(batchSize)
                            .flushInterval(1000)
                            .bufferLimit(batchSize * 2)
                            .jitterInterval(1000)
                            .retryInterval(5000)
                            .maxRetries(5)
                            .maxRetryDelay(30000)
                            .exponentialBase(2)
                            .build();
                    
                    // Create client and write API
                    influxDBClient = InfluxDBClientFactory.create(influxUrl, token.toCharArray(), org, bucket);
                    writeApi = influxDBClient.makeWriteApi(writeOptions);
                    
                    // Test connection by checking if we can ping the server
                    try {
                        influxDBClient.ping();
                        LOG.info("InfluxDB ping successful");
                    } catch (Exception e) {
                        throw new Exception("InfluxDB ping failed: " + e.getMessage());
                    }
                    
                    connected = true;
                    LOG.info("Connected to InfluxDB at {}", influxUrl);
                } catch (Exception e) {
                    lastException = e;
                    retries++;
                    LOG.warn("Failed to connect to InfluxDB (attempt {}/{}): {}", 
                            retries, MAX_RETRIES, e.getMessage());
                    
                    if (retries < MAX_RETRIES) {
                        try {
                            LOG.info("Waiting {} ms before next connection attempt", RETRY_DELAY_MS);
                            Thread.sleep(RETRY_DELAY_MS);
                        } catch (InterruptedException ie) {
                            Thread.currentThread().interrupt();
                            throw new Exception("Connection retry interrupted", ie);
                        }
                    }
                }
            }
            
            if (!connected) {
                LOG.error("Failed to connect to InfluxDB after {} attempts", MAX_RETRIES);
                throw lastException;
            }
        }
        
        @Override
        public void invoke(List<Point> points, Context context) throws Exception {
            int retries = 0;
            Exception lastException = null;
            boolean success = false;
            
            while (!success && retries < MAX_RETRIES) {
                try {
                    // Write points in bulk
                    writeApi.writePoints(points);
                    LOG.info("Successfully wrote {} points to InfluxDB", points.size());
                    success = true;
                } catch (Exception e) {
                    lastException = e;
                    retries++;
                    LOG.warn("Error writing points to InfluxDB (attempt {}/{}): {}", 
                            retries, MAX_RETRIES, e.getMessage());
                    
                    if (retries < MAX_RETRIES) {
                        try {
                            LOG.info("Waiting {} ms before retry", RETRY_DELAY_MS);
                            Thread.sleep(RETRY_DELAY_MS);
                            
                            // Check connection and reconnect if needed
                            try {
                                influxDBClient.ping();
                            } catch (Exception ce) {
                                LOG.info("InfluxDB connection check failed, attempting to reconnect");
                                connectWithRetry();
                            }
                        } catch (InterruptedException ie) {
                            Thread.currentThread().interrupt();
                            throw new Exception("Operation interrupted", ie);
                        }
                    }
                }
            }
            
            if (!success) {
                LOG.error("Failed to write points to InfluxDB after {} attempts", MAX_RETRIES);
                throw lastException;
            }
        }
        
        @Override
        public void close() {
            if (writeApi != null) {
                try {
                    writeApi.close();
                } catch (Exception e) {
                    LOG.error("Error closing WriteApi", e);
                }
            }
            
            if (influxDBClient != null) {
                try {
                    influxDBClient.close();
                } catch (Exception e) {
                    LOG.error("Error closing InfluxDBClient", e);
                }
            }
        }
    }
}
