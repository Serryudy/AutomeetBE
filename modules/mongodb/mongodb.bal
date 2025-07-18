import ballerinax/mongodb;
import ballerina/log;

// MongoDB client configuration - using configurable values from Config.toml
public configurable string mongoDbUrl = "mongodb+srv://pabasara:20020706@mycluster.cb3avmr.mongodb.net/?retryWrites=true&w=majority&appName=mycluster";  // This will read from Config.toml
public configurable string dbName = "automeet";      // This will read from Config.toml

// MongoDB client
public mongodb:Client dbClient = initMongoDbClient();

// Database instance
public mongodb:Database db = initMongoDbDatabase();
public type Update mongodb:Update;
public type UpdateResult mongodb:UpdateResult;
public type Database mongodb:Database;
public type Collection mongodb:Collection;
public type FindOptions mongodb:FindOptions;

// Collection references - initialized through functions to avoid the check keyword at module level
public mongodb:Collection userCollection = getCollectionRef("user");
public mongodb:Collection meetingCollection = getCollectionRef("meetings");
public mongodb:Collection contactCollection = getCollectionRef("contacts");
public mongodb:Collection groupCollection = getCollectionRef("groups");
public mongodb:Collection meetinguserCollection = getCollectionRef("meetingusers");
public mongodb:Collection availabilityCollection = getCollectionRef("availability");
public mongodb:Collection notificationCollection = getCollectionRef("notifications");
public mongodb:Collection participantAvailabilityCollection = getCollectionRef("participantavailability");
public mongodb:Collection notificationSettingsCollection = getCollectionRef("notification_settings");
public mongodb:Collection temporarySuggestionsCollection = getCollectionRef("temporarysuggestions");
public mongodb:Collection chatroomCollection = getCollectionRef("chatrooms");
public mongodb:Collection messageCollection = getCollectionRef("messages");
public mongodb:Collection transcriptCollection = getCollectionRef("transcripts");
public mongodb:Collection contentCollection = getCollectionRef("content");
public mongodb:Collection analyticsCollection = getCollectionRef("analytics");
public mongodb:Collection noteCollection = getCollectionRef("notes");
public mongodb:Collection availabilityNotificationStatusCollection = getCollectionRef("availability_notification_status");
public mongodb:Collection externalUserMappingCollection = getCollectionRef("externalUserMappings");
public final mongodb:Collection aiReportCollection = getCollectionRef("aiReports");

// Initialize MongoDB client - handles the error internally
function initMongoDbClient() returns mongodb:Client {
    mongodb:Client|error dbclient = new ({
        connection: mongoDbUrl
    });
    
    if dbclient is error {
        panic error("Failed to initialize MongoDB client: " + dbclient.message());
    }
    
    log:printInfo("MongoDB client initialized successfully");
    return dbclient;
}

// Initialize MongoDB database - handles the error internally
function initMongoDbDatabase() returns mongodb:Database {
    mongodb:Database|error database = dbClient->getDatabase(dbName);
    
    if database is error {
        panic error("Failed to get MongoDB database: " + database.message());
    }
    
    log:printInfo("MongoDB database initialized successfully");
    return database;
}

// Get collection reference - handles the error internally
function getCollectionRef(string collectionName) returns mongodb:Collection {
    mongodb:Collection|error collection = db->getCollection(collectionName);
    
    if collection is error {
        panic error("Failed to get collection '" + collectionName + "': " + collection.message());
    }
    
    return collection;
}

// Function to close connection - using the correct arrow syntax for remote method calls
public function closeConnection() {
    var result = dbClient->close();
    if result is error {
        log:printError("Error closing MongoDB connection", result);
    } else {
        log:printInfo("MongoDB connection closed successfully");
    }
}

// Public function to get a collection by name
public function getCollection(string collectionName) returns mongodb:Collection|error {
    return db->getCollection(collectionName);
}