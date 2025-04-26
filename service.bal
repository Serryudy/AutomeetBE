import ballerina/http;
import ballerina/log;
import ballerina/jwt;
import ballerina/time;
import ballerina/url;
import ballerina/uuid;
import ballerina/crypto;
import ballerina/email;
import ballerina/regex;
import ballerina/io;
import mongodb_atlas_app.mongodb;

type MeetingType "direct" | "group" | "round_robin";
type NotificationType "creation" | "cancellation" | "confirmation" | "availability_request";
type MeetingStatus "pending" | "confirmed" | "canceled";

// Extended User record definition with calendar connection fields
type User record {
    string username;
    string name = "";
    string password;
    boolean isadmin = false;
    string role = ""; 
    string phone_number = "";
    string profile_pic = "";
    string googleid = "";
    string bio = "";
    string mobile_no = "";
    string time_zone = "";
    string social_media = "";
    string industry = "";
    string company = "";
    boolean is_available = true;
    boolean calendar_connected = false;
    string refresh_token = "";
    string email_refresh_token = "";
};

type RefreshTokenRequest record {
    string refresh_token;
};

type TokenResponse record {
    string access_token;
    string refresh_token;
};

// Simplified SignupRequest to only include required fields
type SignupRequest record {
    string username;
    string name;
    string password;
};

// Login request payload
type LoginRequest record {
    string username;
    string password;
};

// Google login request payload
type GoogleLoginRequest record {
    string googleid;
    string email;
    string name;
    string picture = "";
};

// Login response with user info (no token since it will be in cookie)
type LoginResponse record {
    string username;
    string name;
    boolean isadmin;
    string role;
    boolean success;
    boolean calendar_connected;
};

// Calendar connection status response
type CalendarConnectionResponse record {
    boolean connected;
    string message;
};

type EmailConfig record {
    string host;
    string username;
    string password;
    int port = 465;  // Default port for SSL
    string frontendUrl = "http://localhost:3000"; // Frontend URL for links
};


type MeetingParticipant record {
    string username;
    string access = "pending"; // can be "pending", "accepted", "declined"
};

type MeetingAssignment record {
    string id;
    string username;  // Changed from userId
    string meetingId;
    boolean isAdmin;
};

type Notification record {
    string id;
    string title;
    string message;
    NotificationType notificationType;
    string meetingId;
    string[] toWhom; // Array of usernames who should receive this notification
    string createdAt; // ISO format timestamp
    boolean isRead = false;
};

type ParticipantAvailability record {
    string id;
    string username;
    string meetingId;
    TimeSlot[] timeSlots;
    string submittedAt; // ISO format timestamp
};

type TimeSlot record {
    string startTime;
    string endTime;
    boolean isBestTimeSlot?; // Optional field to mark the best time slot
};

type Meeting record {
    string id;
    string title;
    string location;
    MeetingType meetingType;
    MeetingStatus status = "pending";
    
    // Common fields
    string description;
    string createdBy;
    string repeat = "none"; // can be "none", "daily", "weekly", "monthly", "yearly"
    
    // Type-specific fields - made optional
    TimeSlot? directTimeSlot?;
    string? deadline?; // Deadline for marking availability (ISO format)
    
    string? groupDuration?;
    string? roundRobinDuration?;
    
    MeetingParticipant[]? hosts?;
    MeetingParticipant[]? participants?;
};

type Contact record {
    string id;
    string username;
    string email;
    string phone;
    string profileimg = "";
    string createdBy;
};

type NotificationSettings record {
    string id;
    string username;
    boolean notifications_enabled = true;
    boolean email_notifications = false;
    boolean sms_notifications = false;
    string createdAt;
    string updatedAt;
};

type EmailTemplate record {
    string subject;
    string bodyTemplate;
};

type Availability record {
    string id;
    string username;
    string meetingId;
    TimeSlot[] timeSlots;
};

type Group record {
    string id;
    string name;
    string[] contactIds;
    string createdBy;
};

type DirectMeetingRequest record {
    string title;
    string location;
    string description;
    TimeSlot directTimeSlot;
    string[] participantIds;
    string repeat = "none";
};

type GroupMeetingRequest record {
    string title;
    string location;
    string description;
    TimeSlot[] groupTimeSlots;
    string groupDuration;
    string[] participantIds;
    string repeat = "none";
};

type RoundRobinMeetingRequest record {
    string title;
    string location;
    string description;
    TimeSlot[] roundRobinTimeSlots;
    string roundRobinDuration;
    string[] hostIds;
    string[] participantIds;
    string repeat = "none";
};

// Error response record
type ErrorResponse record {
    string message;
    int statusCode;
};

// Google OAuth config - add your client values in production
configurable string googleClientId = "751259024059-q80a9la618pq41b7nnua3gigv29e0f46.apps.googleusercontent.com";
configurable string googleClientSecret = "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";
configurable string googleRedirectUri = "http://localhost:8080/api/auth/google/callback";
configurable string googleCalendarRedirectUri = "http://localhost:8080/api/auth/google/calendar/callback";
configurable string frontendBaseUrl = "http://localhost:3000";

// JWT signing key - in production, this should be in a secure configuration
final string & readonly JWT_SECRET = "6be1b0ba9fd7c089e3f8ce1bdfcd97613bbe986cf45c1eaec198108bad119bcbfe2088b317efb7d30bae8e60f19311ff13b8990bae0c80b4cb5333c26abcd27190d82b3cd999c9937647708857996bb8b836ee4ff65a31427d1d2c5c59ec67cb7ec94ae34007affc2722e39e7aaca590219ce19cec690ffb7846ed8787296fd679a5a2eadb7d638dc656917f837083a9c0b50deda759d453b8c9a7a4bb41ae077d169de468ec225f7ba21d04219878cd79c9329ea8c29ce8531796a9cc01dd200bb683f98585b0f98cffbf67cf8bafabb8a2803d43d67537298e4bf78c1a05a76342a44b2cf7cf3ae52b78469681b47686352122f8f1af2427985ec72783c06e";

// Function to hash passwords using SHA-256
function hashPassword(string password) returns string {
    byte[] hashedBytes = crypto:hashSha256(password.toBytes());
    return hashedBytes.toBase16();
}

@http:ServiceConfig {
    cors: {
        allowOrigins: ["http://localhost:3000"],
        allowCredentials: true,
        allowHeaders: ["content-type", "authorization"],
        allowMethods: ["POST", "GET", "OPTIONS", "PUT", "DELETE"],
        maxAge: 84900
    }
}

service /api on new http:Listener(8080) {
    resource function put users/edit(http:Request req) returns User|ErrorResponse|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Parse the request payload
        json|http:ClientError jsonPayload = req.getJsonPayload();
        if jsonPayload is http:ClientError {
            return {
                message: "Invalid request payload: " + jsonPayload.message(),
                statusCode: 400
            };
        }
        
        // Create a filter to find the user
        map<json> filter = {
            "username": username
        };
        
        // Get current user data
        record {}|() userRecord = check mongodb:userCollection->findOne(filter);
        if userRecord is () {
            return {
                message: "User not found",
                statusCode: 404
            };
        }
        
        // Convert current user record to User type
        json userJson = userRecord.toJson();
        User currentUser = check userJson.cloneWithType(User);
        
        // Extract fields from payload for update
        map<json> updateFields = <map<json>>jsonPayload;
        map<json> updateOperations = {};
        
        // Update name if provided
        if updateFields.hasKey("name") {
            string nameValue = (updateFields["name"] ?: "").toString();
            updateOperations["name"] = nameValue;
            currentUser.name = nameValue;
        }
        
        // Update phone_number if provided
        if updateFields.hasKey("phone_number") {
            string phoneValue = (updateFields["phone_number"] ?: "").toString();
            updateOperations["phone_number"] = phoneValue;
            currentUser.phone_number = phoneValue;
        }
        
        // Update profile_pic if provided
        if updateFields.hasKey("profile_pic") {
            string picValue = (updateFields["profile_pic"] ?: "").toString();
            updateOperations["profile_pic"] = picValue;
            currentUser.profile_pic = picValue;
        }
        
        // Update bio if provided
        if updateFields.hasKey("bio") {
            string bioValue = (updateFields["bio"] ?: "").toString();
            updateOperations["bio"] = bioValue;
            currentUser.bio = bioValue;
        }
        
        // Update mobile_no if provided
        if updateFields.hasKey("mobile_no") {
            string mobileValue = (updateFields["mobile_no"] ?: "").toString();
            updateOperations["mobile_no"] = mobileValue;
            currentUser.mobile_no = mobileValue;
        }
        
        // Update time_zone if provided
        if updateFields.hasKey("time_zone") {
            string tzValue = (updateFields["time_zone"] ?: "").toString();
            updateOperations["time_zone"] = tzValue;
            currentUser.time_zone = tzValue;
        }
        
        // Update social_media if provided
        if updateFields.hasKey("social_media") {
            string socialValue = (updateFields["social_media"] ?: "").toString();
            updateOperations["social_media"] = socialValue;
            currentUser.social_media = socialValue;
        }
        
        // Update industry if provided
        if updateFields.hasKey("industry") {
            string industryValue = (updateFields["industry"] ?: "").toString();
            updateOperations["industry"] = industryValue;
            currentUser.industry = industryValue;
        }
        
        // Update company if provided
        if updateFields.hasKey("company") {
            string companyValue = (updateFields["company"] ?: "").toString();
            updateOperations["company"] = companyValue;
            currentUser.company = companyValue;
        }
        
        // Update is_available if provided
        if updateFields.hasKey("is_available") {
            json availableValue = updateFields["is_available"];
            boolean boolValue;
            
            if availableValue is boolean {
                boolValue = availableValue;
            } else {
                // Try to convert to boolean
                if availableValue.toString() == "true" {
                    boolValue = true;
                } else if availableValue.toString() == "false" {
                    boolValue = false;
                } else {
                    boolValue = true; // Default to true if conversion fails
                }
            }
            
            updateOperations["is_available"] = boolValue;
            currentUser.is_available = boolValue;
        }
        
        // If no editable fields were provided
        if updateOperations.length() == 0 {
            return {
                message: "No valid fields to update",
                statusCode: 400
            };
        }
        
        // Create update operation with proper MongoDB type
        mongodb:Update updateOperation = {
            "set": updateOperations
        };
        
        // Update user in database
        _ = check mongodb:userCollection->updateOne(filter, updateOperation);
        
        // Remove sensitive information before returning
        currentUser.password = "";
        
        return currentUser;
    }

    resource function get users/profile(http:Request req) returns User|ErrorResponse|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Create a filter to find the user
        map<json> filter = {
            "username": username
        };
        
        // Get user data
        record {}|() userRecord = check mongodb:userCollection->findOne(filter);
        if userRecord is () {
            return {
                message: "User not found",
                statusCode: 404
            };
        }
        
        // Convert to User type
        json userJson = userRecord.toJson();
        User user = check userJson.cloneWithType(User);
        
        // Remove sensitive information
        user.password = "";
        
        return user;
    }

    // Updated endpoint to create a new meeting with cookie authentication
    resource function post direct/meetings(http:Request req) returns Meeting|ErrorResponse|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Parse the request payload
        json|http:ClientError jsonPayload = req.getJsonPayload();
        if jsonPayload is http:ClientError {
            return {
                message: "Invalid request payload: " + jsonPayload.message(),
                statusCode: 400
            };
        }
        
        DirectMeetingRequest payload = check jsonPayload.cloneWithType(DirectMeetingRequest);
        
        // Generate a unique meeting ID
        string meetingId = uuid:createType1AsString();
        
        // Process participants
        MeetingParticipant[] participants = check self.processParticipants(
            username, 
            payload.participantIds
        );
        
        // Create the meeting record
        Meeting meeting = {
            id: meetingId,
            title: payload.title,
            location: payload.location,
            meetingType: "direct",
            description: payload.description,
            createdBy: username,
            repeat: payload.repeat,
            directTimeSlot: payload.directTimeSlot,
            participants: participants
        };

        MeetingAssignment meetingAssignment = {
            id: uuid:createType1AsString(),
            username: username,
            meetingId: meetingId,
            isAdmin: true
        };
        
        // Insert the meeting into MongoDB
        _ = check mongodb:meetingCollection->insertOne(meeting);
        _ = check mongodb:meetinguserCollection->insertOne(meetingAssignment);
        
        // Check if the meeting time is in the future
        TimeSlot _ = payload.directTimeSlot;
        
        // Create and insert notification
        Notification notification = check self.createMeetingNotification(
            meetingId, 
            meeting.title, 
            "direct", 
            participants
        );
        
        // Add the creator to the notification recipients
        notification.toWhom.push(username);
        
        // Insert the notification
        _ = check mongodb:notificationCollection->insertOne(notification);
        
        return meeting;
    }

    // Updated Group Meeting Creation Endpoint with cookie authentication
    resource function post group/meetings(http:Request req) returns Meeting|ErrorResponse|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Parse the request payload
        json|http:ClientError jsonPayload = req.getJsonPayload();
        if jsonPayload is http:ClientError {
            return {
                message: "Invalid request payload: " + jsonPayload.message(),
                statusCode: 400
            };
        }
        
        GroupMeetingRequest payload = check jsonPayload.cloneWithType(GroupMeetingRequest);
        
        // Generate a unique meeting ID
        string meetingId = uuid:createType1AsString();

        // Process participants
        MeetingParticipant[] participants = check self.processParticipants(
            username, 
            payload.participantIds
        );
        
        // Create the meeting record - without time slots
        Meeting meeting = {
            id: meetingId,
            title: payload.title,
            location: payload.location,
            meetingType: "group",
            description: payload.description,
            createdBy: username,
            repeat: payload.repeat,
            groupDuration: payload.groupDuration,
            participants: participants
        };

        MeetingAssignment meetingAssignment = {
            id: uuid:createType1AsString(),
            username: username,
            meetingId: meetingId,
            isAdmin: true
        };
        
        // Insert the meeting into MongoDB
        _ = check mongodb:meetingCollection->insertOne(meeting);
        _ = check mongodb:meetinguserCollection->insertOne(meetingAssignment);
        
        // Store creator's availability in the availability collection
        Availability creatorAvailability = {
            id: uuid:createType1AsString(),
            username: username,
            meetingId: meetingId,
            timeSlots: payload.groupTimeSlots
        };
        
        _ = check mongodb:availabilityCollection->insertOne(creatorAvailability);
        
        // Create and insert notification
        Notification notification = check self.createMeetingNotification(
            meetingId, 
            meeting.title, 
            "group", 
            participants
        );
        
        // Add the creator to the notification recipients
        notification.toWhom.push(username);
        
        // Insert the notification
        _ = check mongodb:notificationCollection->insertOne(notification);
        
        return meeting;
    }

    // Updated Round Robin Meeting Creation Endpoint with cookie authentication
    resource function post roundrobin/meetings(http:Request req) returns Meeting|ErrorResponse|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Parse the request payload
        json|http:ClientError jsonPayload = req.getJsonPayload();
        if jsonPayload is http:ClientError {
            return {
                message: "Invalid request payload: " + jsonPayload.message(),
                statusCode: 400
            };
        }
        
        RoundRobinMeetingRequest payload = check jsonPayload.cloneWithType(RoundRobinMeetingRequest);
        
        // Generate a unique meeting ID
        string meetingId = uuid:createType1AsString();
        
        // Process hosts
        MeetingParticipant[] hosts = check self.processHosts(
            username, 
            payload.hostIds
        );
        
        // Process participants
        MeetingParticipant[] participants = check self.processParticipants(
            username, 
            payload.participantIds
        );
        
        // Create the meeting record - without time slots
        Meeting meeting = {
            id: meetingId,
            title: payload.title,
            location: payload.location,
            meetingType: "round_robin",
            description: payload.description,
            createdBy: username,
            repeat: payload.repeat,
            roundRobinDuration: payload.roundRobinDuration,
            hosts: hosts,
            participants: participants
        };
        
        // Create meeting assignments for the meeting creator
        MeetingAssignment creatorAssignment = {
            id: uuid:createType1AsString(),
            username: username,
            meetingId: meetingId,
            isAdmin: true
        };
        _ = check mongodb:meetinguserCollection->insertOne(creatorAssignment);
        
        // Create meeting assignments for each host
        foreach MeetingParticipant host in hosts {
            MeetingAssignment hostAssignment = {
                id: uuid:createType1AsString(),
                username: host.username,
                meetingId: meetingId,
                isAdmin: true
            };
            _ = check mongodb:meetinguserCollection->insertOne(hostAssignment);
        }
        
        // Store creator's availability in the availability collection
        Availability creatorAvailability = {
            id: uuid:createType1AsString(),
            username: username,
            meetingId: meetingId,
            timeSlots: payload.roundRobinTimeSlots
        };
        
        _ = check mongodb:availabilityCollection->insertOne(creatorAvailability);
        
        // Insert the meeting into MongoDB
        _ = check mongodb:meetingCollection->insertOne(meeting);
        
        // Create and insert notification
        Notification notification = check self.createMeetingNotification(
            meetingId, 
            meeting.title, 
            "round_robin", 
            participants,
            hosts
        );
        
        // Add the creator to the notification recipients
        notification.toWhom.push(username);
        
        // Insert the notification
        _ = check mongodb:notificationCollection->insertOne(notification);
        
        return meeting;
    }

    // endpoint to cancel meetings
     resource function delete meetings/[string meetingId](http:Request req) returns json|http:Response|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            http:Response response = new;
            response.statusCode = 401;
            response.setJsonPayload({
                message: "Unauthorized: Invalid or missing authentication token"
            });
            return response;
        }
        
        // Get the meeting to check if user has permission to cancel
        map<json> filter = {
            "id": meetingId
        };
        
        record {}|() rawMeeting = check mongodb:meetingCollection->findOne(filter);
        if rawMeeting is () {
            http:Response response = new;
            response.statusCode = 404;
            response.setJsonPayload({
                message: "Meeting not found"
            });
            return response;
        }
        
        // Convert to Meeting type
        json meetingJson = rawMeeting.toJson();
        Meeting meeting = check meetingJson.cloneWithType(Meeting);
        
        // Check if the user is the creator or a host
        boolean hasPermission = false;
        
        if meeting.createdBy == username {
            hasPermission = true;
        } else if meeting.meetingType == "round_robin" && meeting?.hosts is MeetingParticipant[] {
            foreach MeetingParticipant host in meeting?.hosts ?: [] {
                if host.username == username {
                    hasPermission = true;
                    break;
                }
            }
        }
        
        if !hasPermission {
            http:Response response = new;
            response.statusCode = 403;
            response.setJsonPayload({
                message: "Unauthorized: Only meeting creators or hosts can cancel meetings"
            });
            return response;
        }
        
        // Collect all related users for notification
        string[] allUsers = [];
        string[] emailRecipients = [];
        foreach string userUsername in allUsers {
            // Get user's notification settings
            map<json> settingsFilter = {
                "username": userUsername
            };
            
            record {}|() settingsRecord = check mongodb:notificationSettingsCollection->findOne(settingsFilter);
            
            if settingsRecord is record {} {
                json settingsJson = settingsRecord.toJson();
                NotificationSettings settings = check settingsJson.cloneWithType(NotificationSettings);
                
                if settings.email_notifications {
                    emailRecipients.push(userUsername);
                }
            }
        }
        // Add creator to users
        allUsers.push(meeting.createdBy);
        
        // Add participants to users
        foreach MeetingParticipant participant in meeting?.participants ?: [] {
            allUsers.push(participant.username);
        }
        
        // Add hosts to users if it's a round robin meeting
        if meeting.meetingType == "round_robin" && meeting?.hosts is MeetingParticipant[] {
            foreach MeetingParticipant host in meeting?.hosts ?: [] {
                // Check if the host is not already in the list (e.g., if creator is also a host)
                boolean alreadyExists = false;
                foreach string existingUser in allUsers {
                    if existingUser == host.username {
                        alreadyExists = true;
                        break;
                    }
                }
                
                if !alreadyExists {
                    allUsers.push(host.username);
                }
            }
        }
        
        // Create cancellation notification
        Notification notification = {
            id: uuid:createType1AsString(),
            title: meeting.title + " Canceled",
            message: "The meeting \"" + meeting.title + "\" has been canceled.",
            notificationType: "cancellation",
            meetingId: meetingId,
            toWhom: allUsers,
            createdAt: time:utcToString(time:utcNow()) // Add the current time as ISO string
        };
        
        // Insert notification
        _ = check mongodb:notificationCollection->insertOne(notification);
        
        // Delete meeting and all related records
        
        // 1. Delete the meeting
        _ = check mongodb:meetingCollection->deleteOne(filter);

        if emailRecipients.length() > 0 {
            // Collect email addresses for all recipients
            map<string> participantEmails = check self.collectParticipantEmails(emailRecipients);
            
            // Send email notifications
            error? emailResult = self.sendEmailNotifications(notification, meeting, participantEmails);
            
            if emailResult is error {
                log:printError("Failed to send email notifications for cancellation", emailResult);
                // Continue execution even if email sending fails
            }
        }
        
        // 2. Delete meeting assignments
        map<json> assignmentFilter = {
            "meetingId": meetingId
        };
        _ = check mongodb:meetinguserCollection->deleteMany(assignmentFilter);
        
        // 3. Delete availabilities
        map<json> availabilityFilter = {
            "meetingId": meetingId
        };
        _ = check mongodb:availabilityCollection->deleteMany(availabilityFilter);
        
        return {
            "status": "success",
            "message": "Meeting canceled successfully"
        };
    }

    //endpoint to fetch notifications
    resource function get notifications(http:Request req) returns Notification[]|http:Response|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            http:Response response = new;
            response.statusCode = 401;
            response.setJsonPayload({
                message: "Unauthorized: Invalid or missing authentication token"
            });
            return response;
        }
        
        // Check if notifications are enabled for this user
        map<json> settingsFilter = {
            "username": username
        };
        
        record {}|() settingsRecord = check mongodb:notificationSettingsCollection->findOne(settingsFilter);
        boolean notificationsEnabled = true; // Default to enabled
        
        if settingsRecord is record {} {
            json settingsJson = settingsRecord.toJson();
            NotificationSettings settings = check settingsJson.cloneWithType(NotificationSettings);
            notificationsEnabled = settings.notifications_enabled;
        }
        
        // If notifications are disabled, return empty array
        if !notificationsEnabled {
            return [];
        }
        
        // Create a filter to find notifications for this user
        map<json> filter = {
            "toWhom": username
        };
        
        // Query the notifications collection
        stream<record {}, error?> notifCursor = check mongodb:notificationCollection->find(filter);
        Notification[] notifications = [];
        
        // Process the results
        check from record {} notifData in notifCursor
            do {
                json notifJson = notifData.toJson();
                Notification notification = check notifJson.cloneWithType(Notification);
                notifications.push(notification);
            };
        
        return notifications;
    }

    // Updated endpoint to submit availability with cookie authentication
    resource function post availability(http:Request req) returns Availability|ErrorResponse|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Parse the request payload
        json|http:ClientError jsonPayload = req.getJsonPayload();
        if jsonPayload is http:ClientError {
            return {
                message: "Invalid request payload: " + jsonPayload.message(),
                statusCode: 400
            };
        }
        Availability payload = check jsonPayload.cloneWithType(Availability);
        
        // Ensure the username in the payload matches the authenticated user
        payload.username = username;
        
        // Generate an ID if not provided
        if (payload.id == "") {
            payload.id = uuid:createType1AsString();
        }
        
        // Check if the meeting exists
        map<json> meetingFilter = {
            "id": payload.meetingId
        };
        
        record {}|() meeting = check mongodb:meetingCollection->findOne(meetingFilter);
        if meeting is () {
            return {
                message: "Meeting not found",
                statusCode: 404
            };
        }
        
        // Check if availability already exists for this user and meeting
        map<json> availFilter = {
            "username": username,
            "meetingId": payload.meetingId
        };
        
        record {}|() existingAvailability = check mongodb:availabilityCollection->findOne(availFilter);
        
        if existingAvailability is () {
            // Insert new availability
            _ = check mongodb:availabilityCollection->insertOne(payload);
        } else {
            // Update existing availability
            _ = check mongodb:availabilityCollection->updateOne(
                availFilter,
                {"set": {"timeSlots": <json>payload.timeSlots}}
            );
        }
        
        return payload;
    }
    
    // Updated endpoint to get availability with cookie authentication
    resource function get availability/[string meetingId](http:Request req) returns Availability[]|ErrorResponse|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Create a filter to find availabilities for this meeting
        map<json> filter = {
            "meetingId": meetingId
        };
        
        // Query the availability collection
        stream<record {}, error?> availCursor = check mongodb:availabilityCollection->find(filter);
        Availability[] availabilities = [];
        
        // Process the results
        check from record {} availData in availCursor
            do {
                json availJson = availData.toJson();
                Availability avail = check availJson.cloneWithType(Availability);
                availabilities.push(avail);
            };
        
        return availabilities;
    }


    // Endpoint to get all confirmed meetings for the logged-in user
    resource function get confirmed/meetings(http:Request req) returns Meeting[]|ErrorResponse|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        Meeting[] confirmedMeetings = [];
        map<string> meetingIds = {}; // To track already added meetings
        
        // 1. Find direct meetings (always confirmed)
        map<json> directFilter = {
            "meetingType": "direct",
            "$or": [
                {"createdBy": username},
                {"participants": {"$elemMatch": {"username": username}}}
            ]
        };
        
        stream<record {}, error?> directCursor = check mongodb:meetingCollection->find(directFilter);
        
        // Process direct meetings
        check from record {} meetingData in directCursor
            do {
                json jsonData = meetingData.toJson();
                Meeting meeting = check jsonData.cloneWithType(Meeting);
                
                // Set role
                if (meeting.createdBy == username) {
                    meeting["role"] = "creator";
                } else {
                    meeting["role"] = "participant";
                }
                
                confirmedMeetings.push(meeting);
                meetingIds[meeting.id] = "added";
            };
        
        // 2. Find confirmed group/round_robin meetings 
        map<json> confirmedFilter = {
            "status": "confirmed",
            "$and": [
                {
                    "$or": [
                        {"meetingType": "group"},
                        {"meetingType": "round_robin"}
                    ]
                },
                {
                    "$or": [
                        {"createdBy": username},
                        {"participants.username": username},
                        {"hosts.username": username}
                    ]
                }
            ]
        };
        
        stream<record {}, error?> confirmedCursor = check mongodb:meetingCollection->find(confirmedFilter);
        
        // Process confirmed meetings
        check from record {} meetingData in confirmedCursor
            do {
                json jsonData = meetingData.toJson();
                Meeting meeting = check jsonData.cloneWithType(Meeting);
                
                // Skip if already added
                if (!meetingIds.hasKey(meeting.id)) {
                    // Determine role
                    if (meeting.createdBy == username) {
                        meeting["role"] = "creator";
                    } else {
                        // Check if user is a host (for round robin)
                        boolean isHost = false;
                        if (meeting.meetingType == "round_robin" && meeting?.hosts is MeetingParticipant[]) {
                            foreach MeetingParticipant host in meeting?.hosts ?: [] {
                                if (host.username == username) {
                                    isHost = true;
                                    break;
                                }
                            }
                        }
                        
                        if (isHost) {
                            meeting["role"] = "host";
                        } else {
                            meeting["role"] = "participant";
                        }
                    }
                    
                    confirmedMeetings.push(meeting);
                    meetingIds[meeting.id] = "added";
                }
            };
        
        // 3. Auto-confirm pending meetings
        // Get all pending meetings related to the user
        map<json> pendingFilter = {
            "status": "pending",
            "$and": [
                {
                    "$or": [
                        {"createdBy": username},
                        {"participants": {"$elemMatch": {"username": username}}},
                        {"hosts": {"$elemMatch": {"username": username}}}
                    ]
                },
                {
                    "$or": [
                        {"meetingType": "group"},
                        {"meetingType": "round_robin"}
                    ]
                }
            ]
        };
        
        stream<record {}, error?> pendingCursor = check mongodb:meetingCollection->find(pendingFilter);
        
        // Process pending meetings and check if they should be confirmed
        check from record {} meetingData in pendingCursor
            do {
                json jsonData = meetingData.toJson();
                Meeting meeting = check jsonData.cloneWithType(Meeting);
                
                // Try to auto-confirm this meeting
                check self.checkAndFinalizeTimeSlot(meeting);
            };
        
        // 4. Run another query to get newly confirmed meetings
        map<json> newlyConfirmedFilter = {
            "status": "confirmed",
            "$and": [
                {
                    "$or": [
                        {"meetingType": "group"},
                        {"meetingType": "round_robin"}
                    ]
                },
                {
                    "$or": [
                        {"createdBy": username},
                        {"participants": {"$elemMatch": {"username": username}}},
                        {"hosts": {"$elemMatch": {"username": username}}}
                    ]
                }
            ]
        };
        
        stream<record {}, error?> newConfirmedCursor = check mongodb:meetingCollection->find(newlyConfirmedFilter);
        
        // Process newly confirmed meetings
        check from record {} meetingData in newConfirmedCursor
            do {
                json jsonData = meetingData.toJson();
                Meeting meeting = check jsonData.cloneWithType(Meeting);
                
                // Skip if already added
                if (!meetingIds.hasKey(meeting.id)) {
                    // Determine role
                    if (meeting.createdBy == username) {
                        meeting["role"] = "creator";
                    } else if (meeting.meetingType == "round_robin") {
                        boolean isHost = false;
                        if (meeting?.hosts is MeetingParticipant[]) {
                            foreach MeetingParticipant host in meeting?.hosts ?: [] {
                                if (host.username == username) {
                                    isHost = true;
                                    break;
                                }
                            }
                        }
                        
                        if (isHost) {
                            meeting["role"] = "host";
                        } else {
                            meeting["role"] = "participant";
                        }
                    } else {
                        meeting["role"] = "participant";
                    }
                    
                    confirmedMeetings.push(meeting);
                }
            };
        
        // 5. Sort the meetings (manual approach without template literals)
        // Separate meetings with and without time slots
        Meeting[] meetingsWithTime = [];
        Meeting[] meetingsWithoutTime = [];
        
        foreach Meeting mtg in confirmedMeetings {
            if mtg?.directTimeSlot is TimeSlot {
                meetingsWithTime.push(mtg);
            } else {
                meetingsWithoutTime.push(mtg);
            }
        }
        
        // Manual bubble sort for meetings with time
        int n = meetingsWithTime.length();
        int i = 0;
        while (i < n - 1) {
            int j = 0;
            while (j < n - i - 1) {
                TimeSlot ts1 = <TimeSlot>meetingsWithTime[j]?.directTimeSlot;
                TimeSlot ts2 = <TimeSlot>meetingsWithTime[j + 1]?.directTimeSlot;
                
                if (ts1.startTime > ts2.startTime) {
                    // Swap
                    Meeting temp = meetingsWithTime[j];
                    meetingsWithTime[j] = meetingsWithTime[j + 1];
                    meetingsWithTime[j + 1] = temp;
                }
                j = j + 1;
            }
            i = i + 1;
        }
        
        // Combine the sorted arrays
        Meeting[] sortedMeetings = [];
        foreach Meeting mtg in meetingsWithTime {
            sortedMeetings.push(mtg);
        }
        foreach Meeting mtg in meetingsWithoutTime {
            sortedMeetings.push(mtg);
        }
        
        return sortedMeetings;
    }
    
    resource function get meeting/[string meetingId]/availabilities(http:Request req) returns ParticipantAvailability[]|http:Response|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            http:Response response = new;
            response.statusCode = 401;
            response.setJsonPayload({
                message: "Unauthorized: Invalid or missing authentication token"
            });
            return response;
        }
        
        // Check if the meeting exists
        map<json> meetingFilter = {
            "id": meetingId
        };
        
        record {}|() meeting = check mongodb:meetingCollection->findOne(meetingFilter);
        if meeting is () {
            http:Response response = new;
            response.statusCode = 404;
            response.setJsonPayload({
                message: "Meeting not found"
            });
            return response;
        }
        
        // Convert to Meeting type
        json meetingJson = meeting.toJson();
        Meeting meetingData = check meetingJson.cloneWithType(Meeting);
        
        // Verify that the user has permission to view availabilities
        boolean hasPermission = false;
        
        // Creators and hosts can view all availabilities
        if (meetingData.createdBy == username) {
            hasPermission = true;
        } else if (meetingData.meetingType == "round_robin" && meetingData?.hosts is MeetingParticipant[]) {
            foreach MeetingParticipant host in meetingData?.hosts ?: [] {
                if (host.username == username) {
                    hasPermission = true;
                    break;
                }
            }
        } else {
            // Check if user is a participant
            if (meetingData?.participants is MeetingParticipant[]) {
                foreach MeetingParticipant participant in meetingData?.participants ?: [] {
                    if (participant.username == username) {
                        hasPermission = true;
                        break;
                    }
                }
            }
        }
        
        if (!hasPermission) {
            http:Response response = new;
            response.statusCode = 403;
            response.setJsonPayload({
                message: "Unauthorized: You don't have access to this meeting's availability data"
            });
            return response;
        }
        
        // Create a filter to find availabilities for this meeting
        map<json> filter = {
            "meetingId": meetingId
        };
        
        // Query the participant availability collection
        stream<record {}, error?> availCursor = check mongodb:participantAvailabilityCollection->find(filter);
        ParticipantAvailability[] availabilities = [];
        
        // Process the results
        check from record {} availData in availCursor
            do {
                json availJson = availData.toJson();
                ParticipantAvailability avail = check availJson.cloneWithType(ParticipantAvailability);
                availabilities.push(avail);
            };
        
        // Check for a suggested best time in temporarySuggestionsCollection
        map<json> suggestedTimeFilter = {
            "meetingId": meetingId
        };
        
        record {}|() suggestedTimeRecord = check mongodb:temporarySuggestionsCollection->findOne(suggestedTimeFilter);
        
        // If there's a suggested best time, mark the corresponding time slots
        if (suggestedTimeRecord is record {}) {
            json suggestedTimeJson = suggestedTimeRecord.toJson();
            if (suggestedTimeJson is map<json> && (<map<json>>suggestedTimeJson).hasKey("suggestedTimeSlot")) {
                json suggestedTimeSlotJson = check suggestedTimeJson.suggestedTimeSlot;
                TimeSlot suggestedTimeSlot = check suggestedTimeSlotJson.cloneWithType(TimeSlot);
                
                // Mark the best time slot in each participant's availability
                foreach int i in 0 ..< availabilities.length() {
                    TimeSlot[] timeSlots = availabilities[i].timeSlots;
                    TimeSlot[] updatedTimeSlots = [];
                    
                    foreach TimeSlot slot in timeSlots {
                        // Create a copy of the time slot
                        TimeSlot updatedSlot = slot.clone();
                        
                        // Check if this is the suggested best time slot
                        if (slot.startTime == suggestedTimeSlot.startTime && 
                            slot.endTime == suggestedTimeSlot.endTime) {
                            // Mark this as the best time slot by adding a flag
                            json updatedSlotJson = slot.toJson();
                            map<json> slotMap = <map<json>>updatedSlotJson;
                            slotMap["isBestTimeSlot"] = true;
                            updatedSlot = check slotMap.cloneWithType(TimeSlot);
                        }
                        
                        updatedTimeSlots.push(updatedSlot);
                    }
                    
                    // Update the time slots with the marked best time slot
                    availabilities[i].timeSlots = updatedTimeSlots;
                }
                
                // Create a response object that includes both the availabilities and the best time slot
                http:Response enhancedResponse = new;
                enhancedResponse.setJsonPayload({
                    "availabilities": availabilities.toJson(),
                    "bestTimeSlot": suggestedTimeSlotJson,
                    "hasSuggestedTime": true
                });
                return enhancedResponse;
            }
        }
        
        // If no best time slot was found, return just the availabilities array
        return availabilities;
    }

    resource function put participant/availability(http:Request req) returns ParticipantAvailability|http:Response|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            http:Response response = new;
            response.statusCode = 401;
            response.setJsonPayload({
                message: "Unauthorized: Invalid or missing authentication token"
            });
            return response;
        }
        
        // Parse the request payload
        json|http:ClientError jsonPayload = req.getJsonPayload();
        if jsonPayload is http:ClientError {
            http:Response response = new;
            response.statusCode = 400;
            response.setJsonPayload({
                message: "Invalid request payload: " + jsonPayload.message()
            });
            return response;
        }
        
        ParticipantAvailability payload = check jsonPayload.cloneWithType(ParticipantAvailability);
        
        // Ensure the username in the payload matches the authenticated user
        payload.username = username;
        
        // Generate an ID if not provided
        if (payload.id == "") {
            payload.id = uuid:createType1AsString();
        }
        
        // Set submitted time if not provided
        if (payload.submittedAt == "") {
            payload.submittedAt = time:utcToString(time:utcNow());
        }
        
        // Check if the meeting exists
        map<json> meetingFilter = {
            "id": payload.meetingId
        };
        
        record {}|() meeting = check mongodb:meetingCollection->findOne(meetingFilter);
        if meeting is () {
            http:Response response = new;
            response.statusCode = 404;
            response.setJsonPayload({
                message: "Meeting not found"
            });
            return response;
        }
        
        // Convert meeting to get its type
        json meetingJson = meeting.toJson();
        Meeting meetingData = check meetingJson.cloneWithType(Meeting);
        
        // Verify that the user is a participant or host of the meeting
        boolean isParticipantOrHost = false;
        string userRole = "";
        
        // Check if user is participant
        if (meetingData?.participants is MeetingParticipant[]) {
            foreach MeetingParticipant p in meetingData?.participants ?: [] {
                if (p.username == username) {
                    isParticipantOrHost = true;
                    userRole = "participant";
                    break;
                }
            }
        }
        
        // Check if user is host (for round robin meetings)
        if (!isParticipantOrHost && meetingData.meetingType == "round_robin" && meetingData?.hosts is MeetingParticipant[]) {
            foreach MeetingParticipant h in meetingData?.hosts ?: [] {
                if (h.username == username) {
                    isParticipantOrHost = true;
                    userRole = "host";
                    break;
                }
            }
        }
        
        // Check if user is the creator
        if (!isParticipantOrHost && meetingData.createdBy == username) {
            isParticipantOrHost = true;
            userRole = "creator";
        }
        
        if (!isParticipantOrHost) {
            http:Response response = new;
            response.statusCode = 403;
            response.setJsonPayload({
                message: "Unauthorized: You are not a participant or host of this meeting"
            });
            return response;
        }
        
        // Check if availability already exists for this user and meeting
        map<json> availFilter = {
            "username": username,
            "meetingId": payload.meetingId
        };
        
        record {}|() existingAvailability = check mongodb:participantAvailabilityCollection->findOne(availFilter);
        
        // Convert TimeSlots to a list of json objects explicitly
        json[] timeSlotJsonArray = payload.timeSlots.map(function (TimeSlot slot) returns json {
            return {
                startTime: slot.startTime,
                endTime: slot.endTime
            };
        });
        
        // Prepare the document for insertion or update
        map<json> insertPayload = {
            "id": payload.id,
            "username": payload.username,
            "meetingId": payload.meetingId,
            "timeSlots": timeSlotJsonArray,
            "submittedAt": payload.submittedAt
        };
        
        if existingAvailability is () {
            // Insert new availability
            _ = check mongodb:participantAvailabilityCollection->insertOne(insertPayload);
        } else {
            // Use updateOne with proper mongodb:Update type
            mongodb:Update updateOperation = {
                "set": {
                    "timeSlots": timeSlotJsonArray,
                    "submittedAt": payload.submittedAt
                }
            };
            
            _ = check mongodb:participantAvailabilityCollection->updateOne(
                availFilter,
                updateOperation
            );
        }
        
        // If this is a round robin meeting and the user is a host, check if all hosts have submitted availability
        if (meetingData.meetingType == "round_robin" && userRole == "host") {
            check self.checkAndNotifyParticipantsForRoundRobin(meetingData);
        }
        
        // For any meeting type, check if deadline has passed and find the best time slot
        check self.checkAndFinalizeTimeSlot(meetingData);
        
        return payload;
    }

    // Endpoint to mark all notifications as read for the authenticated user
    resource function put notifications/markallread(http:Request req) returns json|http:Response|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            http:Response response = new;
            response.statusCode = 401;
            response.setJsonPayload({
                message: "Unauthorized: Invalid or missing authentication token"
            });
            return response;
        }
        
        // Create a filter to find all notifications for this user
        map<json> filter = {
            "toWhom": username,
            "isRead": false // Only update unread notifications
        };
        
        // Create the update operation properly typed as mongodb:Update
        mongodb:Update updateOperation = {
            "set": {
                "isRead": true
            }
        };
        
        // Update all matching notifications
        mongodb:UpdateResult result = check mongodb:notificationCollection->updateMany(filter, updateOperation);
        
        // Return the result with count of modified documents
        return {
            "status": "success",
            "message": "All notifications marked as read",
            "modifiedCount": result.modifiedCount
        };
    }

    // Endpoint to mark a single notification as read
    resource function put notifications/[string notificationId]/read(http:Request req) returns json|http:Response|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            http:Response response = new;
            response.statusCode = 401;
            response.setJsonPayload({
                message: "Unauthorized: Invalid or missing authentication token"
            });
            return response;
        }
        
        // Check if the notification exists and is for this user
        map<json> filter = {
            "id": notificationId,
            "toWhom": username
        };
        
        record {}|() notification = check mongodb:notificationCollection->findOne(filter);
        if notification is () {
            http:Response response = new;
            response.statusCode = 404;
            response.setJsonPayload({
                message: "Notification not found or you don't have access to it"
            });
            return response;
        }
        
        // Create the update operation properly typed as mongodb:Update
        mongodb:Update updateOperation = {
            "set": {
                "isRead": true
            }
        };
        
        // Update the notification
        _ = check mongodb:notificationCollection->updateOne(filter, updateOperation);
        
        return {
            "status": "success",
            "message": "Notification marked as read",
            "notificationId": notificationId
        };
    }

    // Endpoint to get participant availability for a meeting (with username filter)
    resource function get participant/availability/[string meetingId](http:Request req) returns ParticipantAvailability[]|http:Response|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            http:Response response = new;
            response.statusCode = 401;
            response.setJsonPayload({
                message: "Unauthorized: Invalid or missing authentication token"
            });
            return response;
        }
        
        // Check if the meeting exists
        map<json> meetingFilter = {
            "id": meetingId
        };
        
        record {}|() meeting = check mongodb:meetingCollection->findOne(meetingFilter);
        if meeting is () {
            http:Response response = new;
            response.statusCode = 404;
            response.setJsonPayload({
                message: "Meeting not found"
            });
            return response;
        }
        
        // Convert to Meeting type
        json meetingJson = meeting.toJson();
        Meeting meetingData = check meetingJson.cloneWithType(Meeting);
        
        // Verify that the user has permission to view availabilities
        boolean hasPermission = false;
        boolean isCreatorOrHost = false;
        
        // Creators and hosts can view all availabilities
        if (meetingData.createdBy == username) {
            hasPermission = true;
            isCreatorOrHost = true;
        } else if (meetingData.meetingType == "round_robin" && meetingData?.hosts is MeetingParticipant[]) {
            foreach MeetingParticipant host in meetingData?.hosts ?: [] {
                if (host.username == username) {
                    hasPermission = true;
                    isCreatorOrHost = true;
                    break;
                }
            }
        }
        
        // Participants can only view their own availability
        if (!hasPermission) {
            // Check if user is a participant
            if (meetingData?.participants is MeetingParticipant[]) {
                foreach MeetingParticipant participant in meetingData?.participants ?: [] {
                    if (participant.username == username) {
                        hasPermission = true;
                        break;
                    }
                }
            }
        }
        
        if (!hasPermission) {
            http:Response response = new;
            response.statusCode = 403;
            response.setJsonPayload({
                message: "Unauthorized: You don't have access to this meeting's availability data"
            });
            return response;
        }
        
        // Create a filter to find availabilities
        map<json> filter;
        
        // Creators and hosts can view all availabilities, participants can only view their own
        if (isCreatorOrHost) {
            filter = {
                "meetingId": meetingId
            };
        } else {
            // For regular participants, only return their own availability
            filter = {
                "meetingId": meetingId,
                "username": username
            };
        }
        
        // Query the participant availability collection
        stream<record {}, error?> availCursor = check mongodb:participantAvailabilityCollection->find(filter);
        ParticipantAvailability[] availabilities = [];
        
        // Process the results
        check from record {} availData in availCursor
            do {
                json availJson = availData.toJson();
                ParticipantAvailability avail = check availJson.cloneWithType(ParticipantAvailability);
                availabilities.push(avail);
            };
        
        // Check for a suggested best time in temporarySuggestionsCollection
        if (isCreatorOrHost) {
            map<json> suggestedTimeFilter = {
                "meetingId": meetingId
            };
            
            record {}|() suggestedTimeRecord = check mongodb:temporarySuggestionsCollection->findOne(suggestedTimeFilter);
            
            // If there's a suggested best time, mark the corresponding time slots
            if (suggestedTimeRecord is record {}) {
                json suggestedTimeJson = suggestedTimeRecord.toJson();
                json suggestedTimeSlotJson = check suggestedTimeJson.suggestedTimeSlot;
                TimeSlot suggestedTimeSlot = check suggestedTimeSlotJson.cloneWithType(TimeSlot);
                
                // Mark the best time slot in each participant's availability
                foreach int i in 0 ..< availabilities.length() {
                    TimeSlot[] timeSlots = availabilities[i].timeSlots;
                    TimeSlot[] updatedTimeSlots = [];
                    
                    foreach TimeSlot slot in timeSlots {
                        // Create a copy of the time slot
                        TimeSlot updatedSlot = slot.clone();
                        
                        // Check if this is the suggested best time slot
                        if (slot.startTime == suggestedTimeSlot.startTime && 
                            slot.endTime == suggestedTimeSlot.endTime) {
                            // Mark this as the best time slot by adding a flag
                            json updatedSlotJson = slot.toJson();
                            map<json> slotMap = <map<json>>updatedSlotJson;
                            slotMap["isBestTimeSlot"] = true;
                            updatedSlot = check slotMap.cloneWithType(TimeSlot);
                        }

                        updatedTimeSlots.push(updatedSlot);
                    }
                    
                    // Update the time slots with the marked best time slot
                    availabilities[i].timeSlots = updatedTimeSlots;
                }
                
                // Add the best time slot as a metadata property to the response
                // Since we can't directly modify the return type, we'll include it in a custom field
                json availabilitiesJson = check  availabilities.toJson().cloneWithType(json);
                
                // Create a response object that includes both the availabilities and the best time slot
                map<json> responseJson = {
                    "availabilities": availabilitiesJson,
                    "bestTimeSlot": suggestedTimeSlotJson,
                    "hasSuggestedTime": true
                };
                
                // Return the enhanced response
                http:Response enhancedResponse = new;
                enhancedResponse.setJsonPayload(responseJson);
                return enhancedResponse;
            }
        }
        
        // If no best time slot was found or the user is not a creator/host,
        // return the regular availabilities array
        return availabilities;
    }

    resource function put notification/settings(http:Request req) returns NotificationSettings|ErrorResponse|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Parse the request payload
        json|http:ClientError jsonPayload = req.getJsonPayload();
        if jsonPayload is http:ClientError {
            return {
                message: "Invalid request payload: " + jsonPayload.message(),
                statusCode: 400
            };
        }
        
        // Look for existing settings
        map<json> filter = {
            "username": username
        };
        
        record {}|() settingsRecord = check mongodb:notificationSettingsCollection->findOne(filter);
        
        // Current time for timestamps
        string currentTime = time:utcToString(time:utcNow());
        
        // Extract settings from payload
        map<json> updateFields = <map<json>>jsonPayload;
        map<json> updateOperations = {
            "updatedAt": currentTime
        };
        
        // Process notification settings fields
        if updateFields.hasKey("notifications_enabled") {
            json notifValue = updateFields["notifications_enabled"];
            boolean boolValue;
            
            if notifValue is boolean {
                boolValue = notifValue;
            } else {
                // Try to convert to boolean
                if notifValue.toString() == "true" {
                    boolValue = true;
                } else if notifValue.toString() == "false" {
                    boolValue = false;
                } else {
                    boolValue = true; // Default to true if conversion fails
                }
            }
            
            updateOperations["notifications_enabled"] = boolValue;
        }
        
        if updateFields.hasKey("email_notifications") {
            json emailNotifValue = updateFields["email_notifications"];
            boolean boolValue;
            
            if emailNotifValue is boolean {
                boolValue = emailNotifValue;
            } else {
                // Try to convert to boolean
                if emailNotifValue.toString() == "true" {
                    boolValue = true;
                } else if emailNotifValue.toString() == "false" {
                    boolValue = false;
                } else {
                    boolValue = false; // Default to false if conversion fails
                }
            }
            
            updateOperations["email_notifications"] = boolValue;
        }
        
        if updateFields.hasKey("sms_notifications") {
            json smsNotifValue = updateFields["sms_notifications"];
            boolean boolValue;
            
            if smsNotifValue is boolean {
                boolValue = smsNotifValue;
            } else {
                // Try to convert to boolean
                if smsNotifValue.toString() == "true" {
                    boolValue = true;
                } else if smsNotifValue.toString() == "false" {
                    boolValue = false;
                } else {
                    boolValue = false; // Default to false if conversion fails
                }
            }
            
            updateOperations["sms_notifications"] = boolValue;
        }
        
        NotificationSettings resultSettings;
        
        // If settings record exists, update it
        if settingsRecord is record {} {
            // Create update operation
            mongodb:Update updateOperation = {
                "set": updateOperations
            };
            
            // Update settings
            _ = check mongodb:notificationSettingsCollection->updateOne(filter, updateOperation);
            
            // Get the updated settings
            record {}|() updatedRecord = check mongodb:notificationSettingsCollection->findOne(filter);
            if updatedRecord is () {
                return {
                    message: "Failed to retrieve updated settings",
                    statusCode: 500
                };
            }
            
            // Convert to NotificationSettings type
            json updatedJson = updatedRecord.toJson();
            resultSettings = check updatedJson.cloneWithType(NotificationSettings);
        } else {
            // Create new settings with proper type conversion
            boolean notificationsEnabled = true;
            boolean emailNotifications = false;
            boolean smsNotifications = false;
            
            // Extract and convert the boolean values
            if updateOperations.hasKey("notifications_enabled") {
                var value = updateOperations["notifications_enabled"];
                if value is boolean {
                    notificationsEnabled = value;
                }
            }
            
            if updateOperations.hasKey("email_notifications") {
                var value = updateOperations["email_notifications"];
                if value is boolean {
                    emailNotifications = value;
                }
            }
            
            if updateOperations.hasKey("sms_notifications") {
                var value = updateOperations["sms_notifications"];
                if value is boolean {
                    smsNotifications = value;
                }
            }
            
            // Create the settings record with the converted values
            NotificationSettings newSettings = {
                id: uuid:createType1AsString(),
                username: username,
                notifications_enabled: notificationsEnabled,
                email_notifications: emailNotifications,
                sms_notifications: smsNotifications,
                createdAt: currentTime,
                updatedAt: currentTime
            };
            
            // Insert new settings
            _ = check mongodb:notificationSettingsCollection->insertOne(newSettings);
            
            resultSettings = newSettings;
        }
        
        return resultSettings;
    }

    // Get notification settings for the authenticated user
    resource function get notification/settings(http:Request req) returns NotificationSettings|ErrorResponse|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Look for existing settings
        map<json> filter = {
            "username": username
        };
        
        record {}|() settingsRecord = check mongodb:notificationSettingsCollection->findOne(filter);
        
        // If no settings found, create default settings
        if settingsRecord is () {
            string currentTime = time:utcToString(time:utcNow());
            NotificationSettings defaultSettings = {
                id: uuid:createType1AsString(),
                username: username,
                notifications_enabled: true,
                email_notifications: false,
                sms_notifications: false,
                createdAt: currentTime,
                updatedAt: currentTime
            };
            
            // Insert default settings
            _ = check mongodb:notificationSettingsCollection->insertOne(defaultSettings);
            return defaultSettings;
        }
        
        // Convert to NotificationSettings type
        json settingsJson = settingsRecord.toJson();
        NotificationSettings settings = check settingsJson.cloneWithType(NotificationSettings);
        
        return settings;
    }

    function checkAndNotifyParticipantsForRoundRobin(Meeting meeting) returns error? {
        if (meeting.meetingType != "round_robin" || meeting?.hosts is () || meeting?.participants is ()) {
            return;
        }
        
        // Get all host usernames
        string[] hostUsernames = [];
        foreach MeetingParticipant host in meeting?.hosts ?: [] {
            hostUsernames.push(host.username);
        }
        
        // If no hosts, return
        if (hostUsernames.length() == 0) {
            return;
        }
        
        // Check if all hosts have submitted availability
        boolean allHostsSubmitted = true;
        
        foreach string hostUsername in hostUsernames {
            map<json> filter = {
                "username": hostUsername,
                "meetingId": meeting.id
            };
            
            record {}|() hostAvail = check mongodb:participantAvailabilityCollection->findOne(filter);
            
            if (hostAvail is ()) {
                allHostsSubmitted = false;
                break;
            }
        }
        
        // If all hosts have submitted, notify participants
        if (allHostsSubmitted) {
            // Get the creator availability to find the deadline
            map<json> creatorAvailFilter = {
                "username": meeting.createdBy,
                "meetingId": meeting.id
            };
            
            record {}|() creatorAvail = check mongodb:availabilityCollection->findOne(creatorAvailFilter);
            
            if (creatorAvail is ()) {
                return; // No deadline info available
            }
            
            json creatorAvailJson = (<record {}>creatorAvail).toJson();
            Availability creatorAvailability = check creatorAvailJson.cloneWithType(Availability);
            
            // Get the earliest time slot as deadline if available
            TimeSlot[] creatorTimeSlots = creatorAvailability.timeSlots;
            if (creatorTimeSlots.length() == 0) {
                return; // No time slots in creator's availability
            }
            
            // Find the earliest time slot
            string? earliestTime = ();
            foreach TimeSlot slot in creatorTimeSlots {
                if (earliestTime is () || slot.startTime < earliestTime) {
                    earliestTime = slot.startTime;
                }
            }
            
            if (earliestTime is ()) {
                return; // No valid deadline
            }
            
            // Create notifications for all participants, regardless of notification settings
            string[] participantUsernames = [];
            foreach MeetingParticipant participant in meeting?.participants ?: [] {
                participantUsernames.push(participant.username);
            }
            
            if (participantUsernames.length() > 0) {
                // Create and insert the notification
                Notification notification = {
                    id: uuid:createType1AsString(),
                    title: meeting.title + " - Please Mark Your Availability",
                    message: "All hosts have submitted their availability for the meeting \"" + meeting.title + 
                            "\". Please mark your availability before " + earliestTime + ".",
                    notificationType: "availability_request",
                    meetingId: meeting.id,
                    toWhom: participantUsernames,
                    createdAt: time:utcToString(time:utcNow())
                };
                
                _ = check mongodb:notificationCollection->insertOne(notification);
                
                // Send email notifications to all participants
                if participantUsernames.length() > 0 {
                    // Collect email addresses for all recipients - don't check notification settings
                    map<string> participantEmails = check self.collectParticipantEmails(participantUsernames);
                    
                    // Send email notifications
                    error? emailResult = self.sendEmailNotifications(notification, meeting, participantEmails);
                    
                    if emailResult is error {
                        log:printError("Failed to send email notifications for availability request", emailResult);
                        // Continue execution even if email sending fails
                    }
                }
            }
        }
        
        return;
    }

    // Function to check if deadline has passed and calculate best time slot
    function checkAndFinalizeTimeSlot(Meeting meeting) returns error? {
        if (meeting.meetingType != "group" && meeting.meetingType != "round_robin") {
            return; // Only applies to group and round robin meetings
        }
        
        // Get the creator's availability to find the deadline
        map<json> creatorAvailFilter = {
            "username": meeting.createdBy,
            "meetingId": meeting.id
        };
        
        record {}|() creatorAvail = check mongodb:availabilityCollection->findOne(creatorAvailFilter);
        
        if (creatorAvail is ()) {
            return; // No deadline info available
        }
        
        json creatorAvailJson = (<record {}>creatorAvail).toJson();
        Availability creatorAvailability = check creatorAvailJson.cloneWithType(Availability);
        
        // Get the earliest time slot as deadline
        TimeSlot[] creatorTimeSlots = creatorAvailability.timeSlots;
        if (creatorTimeSlots.length() == 0) {
            return; // No time slots in creator's availability
        }
        
        // Find the earliest time slot
        string? earliestTime = ();
        foreach TimeSlot slot in creatorTimeSlots {
            if (earliestTime is () || slot.startTime < earliestTime) {
                earliestTime = slot.startTime;
            }
        }
        
        if (earliestTime is ()) {
            io:println("No valid time from earliest time empty");
            return; // No valid deadline
        }
        
        // Check if current time is past the deadline
        time:Utc currentTime = time:utcNow();
        string currentTimeStr = time:utcToString(currentTime);
        boolean deadlinePassed = currentTimeStr > <string>earliestTime;
        
        if (deadlinePassed) {
            // If deadline has passed, notify creator to reschedule
            _ = check self.notifyCreatorToReschedule(meeting, <string>earliestTime);
            return;
        }
        
        // Determine the best time slot based on matching availabilities from both collections
        TimeSlot? bestTimeSlot = check self.findBestTimeSlot(meeting);
        
        if (bestTimeSlot is TimeSlot) {
            map<json> suggestedTimeDoc = {
                "meetingId": meeting.id,
                "suggestedTimeSlot": check bestTimeSlot.cloneWithType(json),
                "isBestTimeSlot": true,
                "createdAt": time:utcToString(time:utcNow())
            };
            mongodb:Update suggestedTimeUpdate = {
                "set": suggestedTimeDoc
            };

            _ = check mongodb:temporarySuggestionsCollection->updateOne(
                {"meetingId": meeting.id}, 
                suggestedTimeUpdate,
                {"upsert": true}
            );
        }
        
        return;
    }

    function findBestTimeSlot(Meeting meeting) returns TimeSlot?|error {
        // 1. Fetch all availabilities from the availability collection (hosts/creator)
        map<json> availFilter = {
            "meetingId": meeting.id
        };
        
        stream<record {}, error?> availCursor = check mongodb:availabilityCollection->find(availFilter);
        Availability[] hostAvailabilities = [];
        
        check from record {} availData in availCursor
            do {
                json availJson = availData.toJson();
                Availability avail = check availJson.cloneWithType(Availability);
                hostAvailabilities.push(avail);
            };
        
        // 2. Fetch participant availabilities from participantAvailability collection
        map<json> participantFilter = {
            "meetingId": meeting.id
        };
        
        stream<record {}, error?> participantCursor = check mongodb:participantAvailabilityCollection->find(participantFilter);
        ParticipantAvailability[] participantAvailabilities = [];
        
        check from record {} availData in participantCursor
            do {
                json availJson = availData.toJson();
                ParticipantAvailability avail = check availJson.cloneWithType(ParticipantAvailability);
                participantAvailabilities.push(avail);
            };
        
        // If there are no host/creator availabilities or participant availabilities, we can't find a slot
        if (hostAvailabilities.length() == 0 || participantAvailabilities.length() == 0) {
            return ();
        }
        
        // Extract all time slots from hosts/creator
        TimeSlot[] hostTimeSlots = [];
        foreach Availability hostAvail in hostAvailabilities {
            foreach TimeSlot slot in hostAvail.timeSlots {
                hostTimeSlots.push(slot);
            }
        }
        
        // Extract all time slots from participants
        TimeSlot[] participantTimeSlots = [];
        foreach ParticipantAvailability participantAvail in participantAvailabilities {
            foreach TimeSlot slot in participantAvail.timeSlots {
                participantTimeSlots.push(slot);
            }
        }
        
        // Create a map to score host time slots based on participant overlaps
        map<int> timeSlotScores = {};
        map<string> timeSlotKeys = {}; // To store actual TimeSlot objects by key
        
        // For each host time slot
        foreach TimeSlot hostSlot in hostTimeSlots {
            string slotKey = hostSlot.startTime + "-" + hostSlot.endTime;
            timeSlotKeys[slotKey] = slotKey; // Store for reference
            
            // Initialize score
            if (!timeSlotScores.hasKey(slotKey)) {
                timeSlotScores[slotKey] = 0;
            }
            
            // Count overlapping participant slots
            foreach TimeSlot participantSlot in participantTimeSlots {
                // Check for overlap: one slot's start time is less than or equal to the other's end time,
                // and one slot's end time is greater than or equal to the other's start time
                if (hostSlot.startTime <= participantSlot.endTime && hostSlot.endTime >= participantSlot.startTime) {
                    // Increase score for this host slot
                    timeSlotScores[slotKey] = timeSlotScores[slotKey] + 1 ?: 0;
                }
            }
        }
        
        // Find the host time slot with the highest score
        TimeSlot? bestTimeSlot = ();
        int highestScore = 0;
        
        foreach TimeSlot hostSlot in hostTimeSlots {
            string slotKey = hostSlot.startTime + "-" + hostSlot.endTime;
            int score = timeSlotScores[slotKey] ?: 0;
            
            if (score > highestScore) {
                highestScore = score;
                bestTimeSlot = hostSlot;
            }
        }
        
        // If we found a best time slot, proceed with notifications
        if (bestTimeSlot is TimeSlot) {
            // Determine decision makers (creator and hosts for round robin)
            string[] decisionMakers = [];
            decisionMakers.push(meeting.createdBy);
            
            if (meeting.meetingType == "round_robin" && meeting?.hosts is MeetingParticipant[]) {
                foreach MeetingParticipant host in meeting?.hosts ?: [] {
                    if (host.username != meeting.createdBy) { // Avoid duplicates
                        decisionMakers.push(host.username);
                    }
                }
            }
            
            // Create suggested time notification for decision makers
            Notification notification = {
                id: uuid:createType1AsString(),
                title: meeting.title + " - Suggested Time",
                message: "Based on everyone's availability, the suggested time for \"" + meeting.title + 
                        "\" is " + bestTimeSlot.startTime + " to " + bestTimeSlot.endTime + 
                        ". Please confirm this time slot via the meeting details page.",
                notificationType: "availability_request",
                meetingId: meeting.id,
                toWhom: decisionMakers,
                createdAt: time:utcToString(time:utcNow())
            };
            
            // Insert the notification
            _ = check mongodb:notificationCollection->insertOne(notification);
            
            // Check which decision makers have email notifications enabled
            string[] emailRecipients = [];
            foreach string recipient in decisionMakers {
                map<json> settingsFilter = {
                    "username": recipient
                };
                
                record {}|() settingsRecord = check mongodb:notificationSettingsCollection->findOne(settingsFilter);
                
                if settingsRecord is record {} {
                    json settingsJson = settingsRecord.toJson();
                    NotificationSettings settings = check settingsJson.cloneWithType(NotificationSettings);
                    
                    if settings.email_notifications {
                        emailRecipients.push(recipient);
                    }
                }
            }
            
            // Handle email notifications
            if (emailRecipients.length() > 0) {
                // Store suggested time in temporary field for email
                TimeSlot originalTimeSlot = meeting?.directTimeSlot ?: bestTimeSlot;
                meeting.directTimeSlot = bestTimeSlot;
                
                // Collect email addresses
                map<string> decisionMakerEmails = check self.collectParticipantEmails(emailRecipients);
                
                // Send email notifications
                error? emailResult = self.sendEmailNotifications(notification, meeting, decisionMakerEmails);
                
                // Restore original state
                meeting.directTimeSlot = originalTimeSlot;
                
                if (emailResult is error) {
                    log:printError("Failed to send email notifications for time suggestion", emailResult);
                    // Continue execution even if email sending fails
                }
            }
            
            // Store the best time slot in a temporary document for later confirmation
            map<json> suggestedTimeDoc = {
                "meetingId": meeting.id,
                "suggestedTimeSlot": check bestTimeSlot.cloneWithType(json),
                "createdAt": time:utcToString(time:utcNow())
            };
            
            // Use upsert to ensure there's only one suggested time per meeting
            mongodb:Update suggestedTimeUpdate = {
                "set": suggestedTimeDoc
            };

            _ = check mongodb:temporarySuggestionsCollection->updateOne(
                {"meetingId": meeting.id}, 
                suggestedTimeUpdate,
                {"upsert": true}
            );
        }
        
        return bestTimeSlot;
    }

    // Endpoint to confirm a suggested meeting time
    resource function post meetings/[string meetingId]/confirm(http:Request req) returns json|http:Response|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            http:Response response = new;
            response.statusCode = 401;
            response.setJsonPayload({
                message: "Unauthorized: Invalid or missing authentication token"
            });
            return response;
        }
        
        // Get the meeting to check if user has permission
        map<json> filter = {
            "id": meetingId
        };
        
        record {}|() rawMeeting = check mongodb:meetingCollection->findOne(filter);
        if rawMeeting is () {
            http:Response response = new;
            response.statusCode = 404;
            response.setJsonPayload({
                message: "Meeting not found"
            });
            return response;
        }
        
        // Convert to Meeting type
        json meetingJson = rawMeeting.toJson();
        Meeting meeting = check meetingJson.cloneWithType(Meeting);
        
        // Check if user has permission to confirm (creator or host)
        boolean hasPermission = false;
        
        if meeting.createdBy == username {
            hasPermission = true;
        } else if meeting.meetingType == "round_robin" && meeting?.hosts is MeetingParticipant[] {
            foreach MeetingParticipant host in meeting?.hosts ?: [] {
                if host.username == username {
                    hasPermission = true;
                    break;
                }
            }
        }
        
        if !hasPermission {
            http:Response response = new;
            response.statusCode = 403;
            response.setJsonPayload({
                message: "Unauthorized: Only meeting creators or hosts can confirm meeting times"
            });
            return response;
        }
        
        // Parse the request payload to get the timeSlot
        json|http:ClientError jsonPayload = req.getJsonPayload();
        if jsonPayload is http:ClientError {
            http:Response response = new;
            response.statusCode = 400;
            response.setJsonPayload({
                message: "Invalid request payload: " + jsonPayload.message()
            });
            return response;
        }
        
        // Extract time slot from payload
        TimeSlot timeSlot;
        
        // Check if payload has timeSlot
        map<json> payload = <map<json>>jsonPayload;
        if !payload.hasKey("timeSlot") {
            // Get the suggested time from temporary collection if no timeSlot provided
            map<json> suggestedTimeFilter = {
                "meetingId": meetingId
            };
            
            record {}|() suggestedTimeRecord = check mongodb:temporarySuggestionsCollection->findOne(suggestedTimeFilter);
            
            if suggestedTimeRecord is () {
                http:Response response = new;
                response.statusCode = 404;
                response.setJsonPayload({
                    message: "No suggested time found for this meeting and no time slot provided"
                });
                return response;
            }
            
            json suggestedTimeJson = (<record {}>suggestedTimeRecord).toJson();
            json suggestedTimeSlotJson = check suggestedTimeJson.suggestedTimeSlot;
            timeSlot = check suggestedTimeSlotJson.cloneWithType(TimeSlot);
        } else {
            // Use the provided time slot
            json timeSlotJson = payload["timeSlot"];
            timeSlot = check timeSlotJson.cloneWithType(TimeSlot);
        }
        
        // Update meeting with confirmed time slot
        mongodb:Update updateDoc = {
            "set": {
                "directTimeSlot": timeSlot.toJson(),
                "status": "confirmed"
            }
        };
        
        _ = check mongodb:meetingCollection->updateOne(
            {"id": meetingId},
            updateDoc
        );
        
        // Notify all participants about the confirmed time
        string[] recipients = [];
        
        // Add creator
        recipients.push(meeting.createdBy);
        
        // Add participants
        foreach MeetingParticipant p in meeting?.participants ?: [] {
            boolean alreadyExists = false;
            foreach string existingUser in recipients {
                if existingUser == p.username {
                    alreadyExists = true;
                    break;
                }
            }
            
            if !alreadyExists {
                recipients.push(p.username);
            }
        }
        
        // Add hosts for round robin meetings
        if meeting.meetingType == "round_robin" && meeting?.hosts is MeetingParticipant[] {
            foreach MeetingParticipant h in meeting?.hosts ?: [] {
                boolean alreadyExists = false;
                foreach string existingUser in recipients {
                    if existingUser == h.username {
                        alreadyExists = true;
                        break;
                    }
                }
                
                if !alreadyExists {
                    recipients.push(h.username);
                }
            }
        }
        
        // Create confirmation notification
        Notification notification = {
            id: uuid:createType1AsString(),
            title: meeting.title + " Confirmed",
            message: "The meeting \"" + meeting.title + "\" has been confirmed for " +
                    timeSlot.startTime + " to " + timeSlot.endTime + ".",
            notificationType: "confirmation",
            meetingId: meetingId,
            toWhom: recipients,
            createdAt: time:utcToString(time:utcNow())
        };
        
        // Insert notification
        _ = check mongodb:notificationCollection->insertOne(notification);
        
        // Handle email notifications
        string[] emailRecipients = [];
        foreach string recipient in recipients {
            // Get user's notification settings
            map<json> settingsFilter = {
                "username": recipient
            };
            
            record {}|() settingsRecord = check mongodb:notificationSettingsCollection->findOne(settingsFilter);
            
            if settingsRecord is record {} {
                json settingsJson = settingsRecord.toJson();
                NotificationSettings settings = check settingsJson.cloneWithType(NotificationSettings);
                
                if settings.email_notifications {
                    emailRecipients.push(recipient);
                }
            }
        }
        
        if emailRecipients.length() > 0 {
            // Update meeting object for email notification
            meeting.directTimeSlot = timeSlot;
            meeting.status = "confirmed";
            
            // Collect email addresses
            map<string> participantEmails = check self.collectParticipantEmails(emailRecipients);
            
            // Send email notifications
            error? emailResult = self.sendEmailNotifications(notification, meeting, participantEmails);
            
            if emailResult is error {
                log:printError("Failed to send email notifications for confirmation", emailResult);
                // Continue execution even if email sending fails
            }
        }
        
        // Clean up the temporary suggestion if it exists
        map<json> suggestedTimeFilter = {
            "meetingId": meetingId
        };
        _ = check mongodb:temporarySuggestionsCollection->deleteOne(suggestedTimeFilter);
        
        return {
            "status": "success",
            "message": "Meeting time confirmed successfully",
            "timeSlot": timeSlot.toJson()
        };
    }
    // Helper function to notify the creator to reschedule
    function notifyCreatorToReschedule(Meeting meeting, string deadline) returns error? {
        // Create notification for the creator
        string[] recipients = [meeting.createdBy];
        
        Notification notification = {
            id: uuid:createType1AsString(),
            title: meeting.title + " - Deadline Passed",
            message: "The deadline (" + deadline + ") for meeting \"" + meeting.title + 
                    "\" has passed without sufficient availability data. Please reschedule the meeting.",
            notificationType: "cancellation", // Using cancellation type for visual distinction
            meetingId: meeting.id,
            toWhom: recipients,
            createdAt: time:utcToString(time:utcNow())
        };
        
        // Insert the notification
        _ = check mongodb:notificationCollection->insertOne(notification);
        
        // Check if creator has email notifications enabled
        map<json> settingsFilter = {
            "username": meeting.createdBy
        };
        
        record {}|() settingsRecord = check mongodb:notificationSettingsCollection->findOne(settingsFilter);
        
        if (settingsRecord is record {}) {
            json settingsJson = settingsRecord.toJson();
            NotificationSettings settings = check settingsJson.cloneWithType(NotificationSettings);
            
            if (settings.email_notifications) {
                // Send email notification
                map<string> creatorEmail = check self.collectParticipantEmails([meeting.createdBy]);
                error? emailResult = self.sendEmailNotifications(notification, meeting, creatorEmail);
                
                if (emailResult is error) {
                    log:printError("Failed to send reschedule email notification to creator", emailResult);
                    // Continue execution even if email sending fails
                }
            }
        }
        
        return;
    }

    
    function processHosts(string creatorUsername, string[] hostIds) returns MeetingParticipant[]|error {
        // If no hosts are provided, return an empty array
        if hostIds.length() == 0 {
            return [];
        }
        
        MeetingParticipant[] processedHosts = [];
        
        // Validate hosts from users collection
        foreach string hostId in hostIds {
            // Create a filter to find the user
            map<json> filter = {
                "username": hostId
            };
            
            // Query the users collection
            record {}|() user = check mongodb:userCollection->findOne(filter);
            
            // If user not found, return an error
            if user is () {
                return error("Invalid host ID: Host must be a registered user");
            }
            
            processedHosts.push({
                username: hostId,
                access: "accepted"  // Hosts always have accepted access
            });
        }
        
        // Ensure at least one host is processed
        if processedHosts.length() == 0 {
            return error("No valid hosts could be processed");
        }
        
        return processedHosts;
    }

    function processParticipants(string creatorUsername, string[] participantIds) returns MeetingParticipant[]|error {
        // If no participants are provided, return an empty array
        if participantIds.length() == 0 {
            return [];
        }
        
        MeetingParticipant[] processedParticipants = [];
        
        // Validate that all participants belong to the user's contacts
        foreach string participantId in participantIds {
            // Create a filter to find the contact
            map<json> filter = {
                "id": participantId,
                "createdBy": creatorUsername
            };
            
            // Query the contacts collection
            record {}|() contact = check mongodb:contactCollection->findOne(filter);
            
            // If contact not found, return an error
            if contact is () {
                return error("Invalid participant ID: Participant must be in the user's contacts");
            }
            
            // Extract the contact's username
            json contactJson = (<record {}>contact).toJson();
            string contactUsername = check contactJson.username.ensureType();
            
            processedParticipants.push({
                username: contactUsername,  // Use the contact's username instead of ID
                access: "pending"
            });
        }
        
        // Ensure at least one participant is processed
        if processedParticipants.length() == 0 {
            return error("No valid participants could be processed");
        }
        
        return processedParticipants;
    }

    resource function post groups(http:Request req) returns Group|ErrorResponse|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Parse the request payload
        json|http:ClientError jsonPayload = req.getJsonPayload();
        if jsonPayload is http:ClientError {
            return {
                message: "Invalid request payload: " + jsonPayload.message(),
                statusCode: 400
            };
        }

        map<json> groupMap = <map<json>>jsonPayload;

        // Generate a unique group ID if not provided
        if !groupMap.hasKey("id") || groupMap["id"] == "" {
            groupMap["id"] = uuid:createType1AsString();
        }

        groupMap["createdBy"] = username;
        
        Group payload = check groupMap.cloneWithType(Group);
        
        // Validate that all contact IDs belong to the authenticated user
        boolean areContactsValid = check self.validateContactIds(username, payload.contactIds);
        if (!areContactsValid) {
            return {
                message: "Invalid contact ID: One or more contacts do not belong to the user",
                statusCode: 400
            };
        }
        
        // Additional validation: Verify that the contacts exist and match the username
        foreach string contactId in payload.contactIds {
            // Create a filter to find the contact
            map<json> filter = {
                "id": contactId,
                "createdBy": username
            };
            
            record {}|() contact = check mongodb:contactCollection->findOne(filter);
            
            // If contact not found, return an error
            if contact is () {
                return {
                    message: "Invalid contact ID: Contact '" + contactId + "' not found in user's contacts",
                    statusCode: 400
                };
            }
            
            // Extract the contact's username to verify it exists
            json contactJson = (<record {}>contact).toJson();
            string? contactUsername = check contactJson.username.ensureType();
            
            if contactUsername is () || contactUsername == "" {
                return {
                    message: "Invalid contact: Contact '" + contactId + "' has no associated username",
                    statusCode: 400
                };
            }
        }

        // Insert the group into MongoDB
        _ = check mongodb:groupCollection->insertOne(payload);
        
        return payload;
    }

    // Updated endpoint to get groups with cookie authentication
    resource function get groups(http:Request req) returns Group[]|ErrorResponse|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }

        // Create a filter to find groups for this user
        map<json> filter = {
            "createdBy": username
        };

        // Query the groups collection
        stream<record {}, error?> groupCursor = check mongodb:groupCollection->find(filter);
        Group[] groups = [];

        check from record{} groupData in groupCursor
            do {
                json groupJson = groupData.toJson();
                Group group = check groupJson.cloneWithType(Group);
                groups.push(group);
            };

        return groups;
    }

    // Updated endpoint to get contact users with cookie authentication
    resource function get contact/users(http:Request req) returns User[]|ErrorResponse|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Create a filter to find contacts for this user
        map<json> contactFilter = {
            "createdBy": username
        };
        
        // Query the contacts collection
        stream<Contact, error?> contactCursor = check mongodb:contactCollection->find(contactFilter);
        Contact[] contacts = [];
        
        // Process the contacts
        check from Contact contact in contactCursor
            do {
                contacts.push(contact);
            };
        
        // Extract usernames from contacts
        string[] contactUsernames = contacts.map(contact => contact.username);
        
        // Filter users based on contact usernames
        map<json> userFilter = {
            "username": {
                "$in": contactUsernames
            }
        };
        
        // Query the users collection
        stream<record {}, error?> userCursor = check mongodb:userCollection->find(userFilter);
        User[] users = [];
        
        // Process the results
        check from record {} userData in userCursor
            do {
                // Convert record to json then map to User type
                json jsonData = userData.toJson();
                User user = check jsonData.cloneWithType(User);
                
                // remove sensitive information like password
                user.password = "";
                
                users.push(user);
            };
        
        return users;
    }
    // Updated endpoint to get contacts with cookie authentication
    resource function get contacts(http:Request req) returns Contact[]|ErrorResponse|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Create a filter to find contacts for this user
        map<json> filter = {
            "createdBy": username
        };
        
        // Query the contacts collection
        stream<Contact, error?> contactCursor = check mongodb:contactCollection->find(filter);
        Contact[] contacts = [];
        
        // Process the results
        check from Contact contact in contactCursor
            do {
                contacts.push(contact);
            };
        
        return contacts;
    }
    
    // Updated endpoint to get meetings with cookie authentication
    resource function get meetings(http:Request req) returns Meeting[]|ErrorResponse|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        Meeting[] meetings = [];
        map<string> meetingIds = {}; // To track already added meetings
        
        // 1. Find meetings created by this user
        map<json> createdByFilter = {
            "createdBy": username
        };
        
        stream<record {}, error?> createdMeetingCursor = check mongodb:meetingCollection->find(createdByFilter);
        
        // Process the results for created meetings
        check from record {} meetingData in createdMeetingCursor
            do {
                json jsonData = meetingData.toJson();
                Meeting meeting = check jsonData.cloneWithType(Meeting);
                // Mark as created by user
                meeting["role"] = "creator";
                meetings.push(meeting);
                meetingIds[meeting.id] = "added"; // Mark as added
            };
        
        // 2. Find meetings where user is a participant
        map<json> participantFilter = {
            "participants": {
                "$elemMatch": {
                    "username": username
                }
            }
        };
        
        stream<record {}, error?> participantMeetingCursor = check mongodb:meetingCollection->find(participantFilter);
        
        // Process the results for participant meetings
        check from record {} meetingData in participantMeetingCursor
            do {
                json jsonData = meetingData.toJson();
                Meeting meeting = check jsonData.cloneWithType(Meeting);
                
                // Skip if already added
                if (meeting.createdBy != username && !meetingIds.hasKey(meeting.id)) {
                    // Mark as participant
                    meeting["role"] = "participant";
                    meetings.push(meeting);
                    meetingIds[meeting.id] = "added"; // Mark as added
                }
            };
        
        // 3. Find meetings where user is a host
        map<json> hostFilter = {
            "hosts": {
                "$elemMatch": {
                    "username": username
                }
            }
        };
        
        stream<record {}, error?> hostMeetingCursor = check mongodb:meetingCollection->find(hostFilter);
        
        // Process the results for host meetings
        check from record {} meetingData in hostMeetingCursor
            do {
                json jsonData = meetingData.toJson();
                Meeting meeting = check jsonData.cloneWithType(Meeting);
                
                // Skip if already added
                if (!meetingIds.hasKey(meeting.id)) {
                    // Mark as host
                    meeting["role"] = "host";
                    meetings.push(meeting);
                    meetingIds[meeting.id] = "added"; // Mark as added
                }
            };
        
        return meetings;
    }
    
    // Updated endpoint to get meeting details by ID with cookie authentication
    resource function get meetings/[string meetingId](http:Request req) returns Meeting|ErrorResponse|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Create a filter to find the meeting by ID
        map<json> filter = {
            "id": meetingId
        };
        
        // Query the meeting without specifying the return type
        record {}|() rawMeeting = check mongodb:meetingCollection->findOne(filter);
        
        if rawMeeting is () {
            return {
                message: "Meeting not found",
                statusCode: 404
            };
        }
        
        // Convert the raw document to JSON then to Meeting type
        json jsonData = rawMeeting.toJson();
        Meeting meeting = check jsonData.cloneWithType(Meeting);
        
        // Determine the user's role in this meeting
        if (meeting.createdBy == username) {
            // User created this meeting
            meeting["role"] = "creator";
        } else {
            // Check if user is a host using $elemMatch approach
            map<json> hostCheckFilter = {
                "id": meetingId,
                "hosts": {
                    "$elemMatch": {
                        "username": username
                    }
                }
            };
            
            record {}|() hostCheck = check mongodb:meetingCollection->findOne(hostCheckFilter);
            
            if (hostCheck is record {}) {
                meeting["role"] = "host";
            } else {
                // Check if user is a participant using $elemMatch approach
                map<json> participantCheckFilter = {
                    "id": meetingId,
                    "participants": {
                        "$elemMatch": {
                            "username": username
                        }
                    }
                };
                
                record {}|() participantCheck = check mongodb:meetingCollection->findOne(participantCheckFilter);
                
                if (participantCheck is record {}) {
                    meeting["role"] = "participant";
                } else {
                    // If user has none of these roles, they shouldn't have access
                    return {
                        message: "Unauthorized: You don't have access to this meeting",
                        statusCode: 403
                    };
                }
            }
        }
        
        // Get only the current user's availability data for this meeting
        map<json> userAvailFilter = {
            "meetingId": meetingId,
            "username": username
        };
        
        record {}|() userAvailData = check mongodb:availabilityCollection->findOne(userAvailFilter);
        
        // Add user's availability if it exists
        if userAvailData is record {} {
            json availJson = userAvailData.toJson();
            Availability userAvail = check availJson.cloneWithType(Availability);
            meeting["userAvailability"] = userAvail;
        }
        
        return meeting;
    }
    
    // Updated endpoint to edit a meeting by ID with proper authorization control
    resource function put meetings/[string meetingId](http:Request req) returns Meeting|error|ErrorResponse {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }

        // Parse the update request payload
        json|http:ClientError jsonPayload = req.getJsonPayload();
        if jsonPayload is http:ClientError {
            return {
                message: "Invalid request payload: " + jsonPayload.message(),
                statusCode: 400
            };
        }

        // Get the existing meeting first
        map<json> filter = {
            "id": meetingId
        };

        record {}|() rawMeeting = check mongodb:meetingCollection->findOne(filter);
        if rawMeeting is () {
            return {
                message: "Meeting not found",
                statusCode: 404
            };
        }

        // Convert to Meeting type
        json meetingJson = rawMeeting.toJson();
        Meeting existingMeeting = check meetingJson.cloneWithType(Meeting);

        // Check user's role in this meeting
        string userRole = "";

        // Check if user is the creator
        if (existingMeeting.createdBy == username) {
            userRole = "creator";
        } else {
            // Check if user is a host
            boolean isHost = false;
            if (existingMeeting?.hosts is MeetingParticipant[]) {
                foreach var host in existingMeeting?.hosts ?: [] {
                    if (host?.username == username) {
                        isHost = true;
                        break;
                    }
                }
            }
            
            if (isHost) {
                userRole = "host";
            } else {
                // If not creator or host, they can't edit
                return {
                    message: "Unauthorized: Only meeting creators and hosts can edit meetings",
                    statusCode: 403
                };
            }
        }

        // Make a copy of the existing meeting for updates
        Meeting updatedMeeting = existingMeeting.clone();

        // Process different parts of the update based on user role
        map<json> updateOperations = {};
        map<json> updatePayload = <map<json>>jsonPayload;

        // Only creators can update these fields
        if (userRole == "creator") {
            // Update basic meeting details if provided in payload
            if (updatePayload.hasKey("title")) {
                string titleValue = (updatePayload["title"] ?: "").toString();
                updatedMeeting.title = titleValue;
                updateOperations["title"] = titleValue;
            }
            
            if (updatePayload.hasKey("location")) {
                string locationValue = (updatePayload["location"] ?: "").toString();
                updatedMeeting.location = locationValue;
                updateOperations["location"] = locationValue;
            }
            
            if (updatePayload.hasKey("description")) {
                string descriptionValue = (updatePayload["description"] ?: "").toString();
                updatedMeeting.description = descriptionValue;
                updateOperations["description"] = descriptionValue;
            }
            
            if (updatePayload.hasKey("repeat")) {
                string repeatValue = (updatePayload["repeat"] ?: "").toString();
                updatedMeeting.repeat = repeatValue;
                updateOperations["repeat"] = repeatValue;
            }
            
            // Handle meeting type specific fields
            if (existingMeeting.meetingType == "direct" && updatePayload.hasKey("directTimeSlot")) {
                json timeSlotJson = updatePayload["directTimeSlot"] ?: {};
                TimeSlot timeSlotValue = check timeSlotJson.cloneWithType(TimeSlot);
                updatedMeeting.directTimeSlot = timeSlotValue;
                updateOperations["directTimeSlot"] = timeSlotJson;
            } else if (existingMeeting.meetingType == "group" && updatePayload.hasKey("groupDuration")) {
                string durationValue = (updatePayload["groupDuration"] ?: "").toString();
                updatedMeeting.groupDuration = durationValue;
                updateOperations["groupDuration"] = durationValue;
            } else if (existingMeeting.meetingType == "round_robin" && updatePayload.hasKey("roundRobinDuration")) {
                string durationValue = (updatePayload["roundRobinDuration"] ?: "").toString();
                updatedMeeting.roundRobinDuration = durationValue;
                updateOperations["roundRobinDuration"] = durationValue;
            }
        }

        // Both creators and hosts can manage participants
        if (userRole == "creator" || userRole == "host") {
            // Add new participants
            if (updatePayload.hasKey("addParticipants")) {
                json[] newParticipantIds = [];
                json addParticipantsValue = updatePayload["addParticipants"];
                
                if addParticipantsValue is json[] {
                    newParticipantIds = addParticipantsValue;
                }
                
                string[] participantIdList = [];
                foreach json id in newParticipantIds {
                    if id is string {
                        participantIdList.push(id);
                    }
                }
                
                // Process and add new participants
                if participantIdList.length() > 0 {
                    MeetingParticipant[] newParticipants = check self.processParticipants(username, participantIdList);
                    
                    // Add only participants that aren't in the meeting already
                    MeetingParticipant[] currentParticipants = existingMeeting?.participants ?: [];
                    foreach var newParticipant in newParticipants {
                        boolean alreadyExists = false;
                        
                        foreach var existingParticipant in currentParticipants {
                            if (existingParticipant.username == newParticipant.username) {
                                alreadyExists = true;
                                break;
                            }
                        }
                        
                        if (!alreadyExists) {
                            currentParticipants.push(newParticipant);
                        }
                    }
                    
                    // Update the participants list
                    json participantsJson = check currentParticipants.cloneWithType(json);
                    updateOperations["participants"] = participantsJson;
                    updatedMeeting.participants = currentParticipants;
                }
            }
            
            // Remove participants
            if (updatePayload.hasKey("removeParticipants")) {
                json[] removeUsernames = [];
                json removeParticipantsValue = updatePayload["removeParticipants"];
                
                if removeParticipantsValue is json[] {
                    removeUsernames = removeParticipantsValue;
                }
                
                string[] usernameList = [];
                foreach json usernameValue in removeUsernames {
                    if usernameValue is string {
                        usernameList.push(usernameValue);
                    }
                }
                
                // Remove specified participants
                if usernameList.length() > 0 {
                    MeetingParticipant[] currentParticipants = existingMeeting?.participants ?: [];
                    MeetingParticipant[] updatedParticipants = [];
                    
                    foreach var participant in currentParticipants {
                        boolean shouldRemove = false;
                        
                        foreach string usernameToRemove in usernameList {
                            if (participant.username == usernameToRemove) {
                                shouldRemove = true;
                                break;
                            }
                        }
                        
                        if (!shouldRemove) {
                            updatedParticipants.push(participant);
                        }
                    }
                    
                    // Update the participants list
                    json participantsJson = check updatedParticipants.cloneWithType(json);
                    updateOperations["participants"] = participantsJson;
                    updatedMeeting.participants = updatedParticipants;
                }
            }
            
            // If this is a round_robin meeting, creators can manage hosts
            if (userRole == "creator" && existingMeeting.meetingType == "round_robin") {
                // Add new hosts
                if (updatePayload.hasKey("addHosts")) {
                    json[] newHostIds = [];
                    json addHostsValue = updatePayload["addHosts"];
                    
                    if addHostsValue is json[] {
                        newHostIds = addHostsValue;
                    }
                    
                    string[] hostIdList = [];
                    foreach json id in newHostIds {
                        if id is string {
                            hostIdList.push(id);
                        }
                    }
                    
                    // Process and add new hosts
                    if hostIdList.length() > 0 {
                        MeetingParticipant[] newHosts = check self.processHosts(username, hostIdList);
                        
                        // Add only hosts that aren't in the meeting already
                        MeetingParticipant[] currentHosts = existingMeeting?.hosts ?: [];
                        foreach var newHost in newHosts {
                            boolean alreadyExists = false;
                            
                            foreach var existingHost in currentHosts {
                                if (existingHost.username == newHost.username) {
                                    alreadyExists = true;
                                    break;
                                }
                            }
                            
                            if (!alreadyExists) {
                                currentHosts.push(newHost);
                                
                                // Also create meeting assignment for the new host
                                MeetingAssignment hostAssignment = {
                                    id: uuid:createType1AsString(),
                                    username: newHost.username,
                                    meetingId: meetingId,
                                    isAdmin: true
                                };
                                _ = check mongodb:meetinguserCollection->insertOne(hostAssignment);
                            }
                        }
                        
                        // Update the hosts list
                        json hostsJson = check currentHosts.cloneWithType(json);
                        updateOperations["hosts"] = hostsJson;
                        updatedMeeting.hosts = currentHosts;
                    }
                }
                
                // Remove hosts
                if (updatePayload.hasKey("removeHosts")) {
                    json[] removeUsernames = [];
                    json removeHostsValue = updatePayload["removeHosts"];
                    
                    if removeHostsValue is json[] {
                        removeUsernames = removeHostsValue;
                    }
                    
                    string[] usernameList = [];
                    foreach json usernameValue in removeUsernames {
                        if usernameValue is string {
                            usernameList.push(usernameValue);
                        }
                    }
                    
                    // Remove specified hosts
                    if usernameList.length() > 0 {
                        MeetingParticipant[] currentHosts = existingMeeting?.hosts ?: [];
                        MeetingParticipant[] updatedHosts = [];
                        
                        foreach var host in currentHosts {
                            boolean shouldRemove = false;
                            
                            foreach string usernameToRemove in usernameList {
                                if (host.username == usernameToRemove) {
                                    shouldRemove = true;
                                    break;
                                }
                            }
                            
                            if (!shouldRemove) {
                                updatedHosts.push(host);
                            } else {
                                // Remove meeting assignment for this host
                                map<json> assignmentFilter = {
                                    "username": host.username,
                                    "meetingId": meetingId
                                };
                                _ = check mongodb:meetinguserCollection->deleteOne(assignmentFilter);
                            }
                        }
                        
                        // Update the hosts list
                        json hostsJson = check updatedHosts.cloneWithType(json);
                        updateOperations["hosts"] = hostsJson;
                        updatedMeeting.hosts = updatedHosts;
                    }
                }
            }
        }

        // Handle time slots for different meeting types
        if (updatePayload.hasKey("timeSlots") && (userRole == "creator" || userRole == "host")) {
            json timeSlotsJson = updatePayload["timeSlots"];
            TimeSlot[] updatedTimeSlots = [];
            
            if timeSlotsJson is json[] {
                updatedTimeSlots = <TimeSlot[]>check timeSlotsJson.cloneWithType();
                
                // For direct meetings, creator can update time slot directly in the meeting document
                if (existingMeeting.meetingType == "direct" && userRole == "creator") {
                    // Single time slot for direct meetings
                    if (updatedTimeSlots.length() > 0) {
                        updatedMeeting.directTimeSlot = updatedTimeSlots[0];
                        updateOperations["directTimeSlot"] = check updatedTimeSlots[0].cloneWithType(json);
                    }
                } else if (existingMeeting.meetingType == "group" || existingMeeting.meetingType == "round_robin") {
                    // For group and round robin meetings, time slots are stored in availability collection
                    
                    // Check if user already has availability entries
                    map<json> availFilter = {
                        "username": username,
                        "meetingId": meetingId
                    };
                    
                    record {}|() existingAvailability = check mongodb:availabilityCollection->findOne(availFilter);
                    
                    if (existingAvailability is ()) {
                        // Create new availability record
                        Availability newAvailability = {
                            id: uuid:createType1AsString(),
                            username: username,
                            meetingId: meetingId,
                            timeSlots: updatedTimeSlots
                        };
                        _ = check mongodb:availabilityCollection->insertOne(newAvailability);
                    } else {
                        // Update existing availability
                        json timeSlotsDataJson = check updatedTimeSlots.cloneWithType(json);
                        mongodb:Update availabilityUpdate = {
                            "set": {"timeSlots": timeSlotsDataJson}
                        };
                        _ = check mongodb:availabilityCollection->updateOne(availFilter, availabilityUpdate);
                    }
                }
            }
        }

        // If there are updates to make to the meeting document
        mongodb:Update updateDoc = {
            "set": updateOperations
        };
        _ = check mongodb:meetingCollection->updateOne(
            {"id": meetingId},
            updateDoc
        );

        // Return the updated meeting with its role
        if (userRole == "creator") {
            updatedMeeting["role"] = "creator";
        } else {
            updatedMeeting["role"] = "host";
        }

        // Get latest availability data for this meeting
        map<json> availFilter = {
            "meetingId": meetingId
        };

        stream<record {}, error?> availCursor = check mongodb:availabilityCollection->find(availFilter);
        Availability[] availabilities = [];

        check from record {} availData in availCursor
            do {
                json availJson = availData.toJson();
                Availability avail = check availJson.cloneWithType(Availability);
                availabilities.push(avail);
            };

        // Get current user's time slots if available
        TimeSlot[] userTimeSlots = [];
        foreach Availability avail in availabilities {
            if avail.username == username {
                userTimeSlots = avail.timeSlots;
                break;
            }
        }

        // Add time slots to the meeting response based on meeting type
        if updatedMeeting.meetingType == "direct" {
            // Direct meetings already have time slots embedded
        } else if updatedMeeting.meetingType == "group" {
            // For group meetings, add the user's time slots
            updatedMeeting["groupTimeSlots"] = userTimeSlots;
        } else if updatedMeeting.meetingType == "round_robin" {
            // For round robin meetings, add the user's time slots
            updatedMeeting["roundRobinTimeSlots"] = userTimeSlots;
        }

        // Add all availabilities for admin/creator view
        if userRole == "creator" || userRole == "host" {
            updatedMeeting["allAvailabilities"] = availabilities;
        }

        return updatedMeeting;
    }

    // Function to validate that all contact IDs belong to the user
    function validateContactIds(string username, string[] contactIds) returns boolean|error {
        // Get all contacts for this user
        map<json> filter = {
            "createdBy": username
        };
        
        // Query the contacts collection
        stream<Contact, error?> contactCursor = check mongodb:contactCollection->find(filter);
        string[] userContactIds = [];
        
        // Process the results to get all contact IDs for this user
        check from Contact contact in contactCursor
            do {
                userContactIds.push(contact.id);
            };
        
        // Check if all provided contact IDs are in the user's contacts
        // Fix: Replace 'includes' with a manual check function
        foreach string contactId in contactIds {
            boolean found = false;
            foreach string userContactId in userContactIds {
                if (userContactId == contactId) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                return false;
            }
        }
        
        return true;
    }
    
    // Updated endpoint to create a new contact with cookie authentication
    resource function post contacts(http:Request req) returns error|ErrorResponse|Contact {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Parse the request payload
        json|http:ClientError jsonPayload = req.getJsonPayload();
        if jsonPayload is http:ClientError {
            return {
                message: "Invalid request payload: " + jsonPayload.message(),
                statusCode: 400
            };
        }
        
        // First convert to a map<json> to handle missing fields
        map<json> contactMap = <map<json>>jsonPayload;
        
        // Set default values for required fields before conversion
        if !contactMap.hasKey("id") || contactMap["id"] == "" {
            contactMap["id"] = uuid:createType1AsString();
        }
        
        // Set the createdBy to the authenticated username
        contactMap["createdBy"] = username;
        
        // Now convert to Contact type
        Contact payload = check contactMap.cloneWithType(Contact);
        
        // Insert the contact into MongoDB
        _ = check mongodb:contactCollection->insertOne(payload);
        
        return payload;
    }
    // New helper function to extract JWT token from cookie
    function validateAndGetUsernameFromCookie(http:Request request) returns string?|error {
        // Try to get the auth_token cookie
        http:Cookie[] cookies = request.getCookies();
        string? token = ();
        
        foreach http:Cookie cookie in cookies {
            if cookie.name == "auth_token" {
                token = cookie.value;
                break;
            }
        }
        
        // If no auth cookie found, check for Authorization header as fallback
        if token is () {
            string authHeader = check request.getHeader("Authorization");
            
            if authHeader.startsWith("Bearer ") {
                token = authHeader.substring(7);
            } else {
                log:printError("No authentication token found in cookies or headers");
                return ();
            }
        }
        
        // Validate the JWT token - Using updated structure for JWT 2.13.0
        jwt:ValidatorConfig validatorConfig = {
            issuer: "automeet",
            audience: "automeet-app",
            clockSkew: 60,
            signatureConfig: {
                secret: JWT_SECRET    // For HMAC based JWT
            }
        };
        
        jwt:Payload|error validationResult = jwt:validate(token, validatorConfig);
        
        if (validationResult is error) {
            log:printError("JWT validation failed", validationResult);
            return ();
        }
        
        jwt:Payload payload = validationResult;
        
        // First check if the username might be in the subject field
        if (payload.sub is string) {
            return payload.sub;
        }
        
        // Direct access to claim using index accessor
        var customClaims = payload["customClaims"];
        if (customClaims is map<json>) {
            var username = customClaims["username"];
            if (username is string) {
                return username;
            }
        }
        
        // Try to access username directly as a rest field
        var username = payload["username"];
        if (username is string) {
            return username;
        }
        
        log:printError("Username not found in JWT token");
        return ();
    }

    function sendEmailNotifications(Notification notification, Meeting meeting, map<string> participantEmails) returns error? {
        // Email configuration
        EmailConfig emailConfig = {
            host: "smtp.gmail.com",
            username: "somapalagalagedara@gmail.com",
            password: "wzhd plxq isxl nddc",
            frontendUrl: "https://localhost:3000" // Update with actual frontend URL
        };
        
        // Create SMTP client
        email:SmtpClient|error smtpClient = new (emailConfig.host, emailConfig.username, emailConfig.password);
        
        if smtpClient is error {
            log:printError("Failed to create SMTP client", smtpClient);
            return smtpClient;
        }
        
        // Get email template based on notification type
        EmailTemplate template = self.getEmailTemplate(notification.notificationType, meeting.title);
        
        // Create a deep link to the meeting
        string meetingLink = emailConfig.frontendUrl + "/meetingsdetails/" + meeting.id;
        
        // Send emails to all recipients
        foreach string username in notification.toWhom {
            // Skip if email doesn't exist for this user
            if !participantEmails.hasKey(username) {
                log:printWarn("No email address found for user: " + username);
                continue;
            }
            
            string recipientEmail = participantEmails[username] ?: "";
            
            // Replace placeholders in template
            string personalizedBody = regex:replace(
                regex:replace(
                    template.bodyTemplate, 
                    "\\{meeting_title\\}", 
                    meeting.title
                ), 
                "\\{meeting_link\\}", 
                meetingLink
            );
                
            // Add meeting details to the email
            personalizedBody = personalizedBody + "\n\nMeeting Details:\n" +
                "Location: " + meeting.location + "\n" +
                "Description: " + meeting.description;
                
            // Add appropriate meeting time information
            if meeting.meetingType == "direct" && meeting?.directTimeSlot is TimeSlot {
                TimeSlot timeSlot = <TimeSlot>meeting?.directTimeSlot;
                personalizedBody = personalizedBody + "\nTime: " + timeSlot.startTime + " to " + timeSlot.endTime;
            } else if meeting.meetingType == "group" || meeting.meetingType == "round_robin" {
                personalizedBody = personalizedBody + "\nPlease mark your availability using the link above.";
            }
            
            // Create email message
            email:Message emailMsg = {
                to: recipientEmail,
                subject: template.subject,
                body: personalizedBody,
                htmlBody: self.getHtmlEmail(meeting.title, personalizedBody, meetingLink)
            };
            
            // Send email
            error? sendResult = smtpClient->sendMessage(emailMsg);
            
            if sendResult is error {
                log:printError("Failed to send email to " + recipientEmail, sendResult);
                // Continue with other emails even if one fails
            } else {
                log:printInfo("Email sent successfully to " + recipientEmail);
            }
        }
        
        return;
    }

    function getEmailTemplate(NotificationType notificationType, string meetingTitle) returns EmailTemplate {
        match notificationType {
            "creation" => {
                return {
                    subject: "[AutoMeet] You've been invited to a meeting: " + meetingTitle,
                    bodyTemplate: "You have been invited to a new meeting: {meeting_title}\n\nPlease click the link below to view the meeting details:\n{meeting_link}"
                };
            }
            "cancellation" => {
                return {
                    subject: "[AutoMeet] Meeting Canceled: " + meetingTitle,
                    bodyTemplate: "The meeting \"{meeting_title}\" has been canceled.\n\nYou can view your upcoming meetings here:\n{meeting_link}"
                };
            }
            "confirmation" => {
                return {
                    subject: "[AutoMeet] Meeting Confirmed: " + meetingTitle,
                    bodyTemplate: "The meeting \"{meeting_title}\" has been confirmed.\n\nPlease click the link below to view the meeting details:\n{meeting_link}"
                };
            }
            "availability_request" => {
                return {
                    subject: "[AutoMeet] Please Mark Your Availability: " + meetingTitle,
                    bodyTemplate: "Please mark your availability for the meeting \"{meeting_title}\".\n\nClick the link below to set your availability:\n{meeting_link}"
                };
            }
            _ => {
                return {
                    subject: "[AutoMeet] Notification: " + meetingTitle,
                    bodyTemplate: "You have a new notification related to the meeting \"{meeting_title}\".\n\nPlease click the link below to view the details:\n{meeting_link}"
                };
            }
        }
    }

    function getHtmlEmail(string meetingTitle, string textContent, string meetingLink) returns string {
        return string `
        <html>
            <head>
                <style>
                    body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
                    .container { max-width: 600px; margin: 0 auto; padding: 20px; }
                    .header { background-color: #4a86e8; color: white; padding: 10px 20px; border-radius: 5px 5px 0 0; }
                    .content { padding: 20px; border: 1px solid #ddd; border-top: none; border-radius: 0 0 5px 5px; }
                    .button { display: inline-block; background-color: #4a86e8; color: white; padding: 10px 20px; 
                            text-decoration: none; border-radius: 5px; margin-top: 15px; }
                    .footer { margin-top: 20px; font-size: 12px; color: #777; text-align: center; }
                </style>
            </head>
            <body>
                <div class="container">
                    <div class="header">
                        <h2>AutoMeet</h2>
                    </div>
                    <div class="content">
                        <h3>${meetingTitle}</h3>
                        <p>${textContent}</p>
                        <a href="${meetingLink}" class="button">View Meeting</a>
                    </div>
                    <div class="footer">
                        <p>This is an automated message from AutoMeet. Please do not reply to this email.</p>
                    </div>
                </div>
            </body>
        </html>
        `;
    }

    
    function collectParticipantEmails(string[] usernames) returns map<string>|error {
        map<string> emails = {};
        
        foreach string usernameToCheck in usernames {
            // Log which username we're processing
            log:printInfo("Finding email for username: " + usernameToCheck);
            
            // Try to find contact directly first
            map<json> contactFilter = {
                "username": usernameToCheck
            };
            
            // Use a try-catch to handle potential errors
            do {
                record {}|() contactRecord = check mongodb:contactCollection->findOne(contactFilter);
                
                if contactRecord is record {} {
                    json contactJson = contactRecord.toJson();
                    map<json> contactMap = <map<json>>contactJson;
                    
                    // Try to extract email using direct field access rather than type conversion
                    string? contactEmail = ();
                    if contactMap.hasKey("email") {
                        var emailValue = contactMap["email"];
                        if emailValue is string {
                            contactEmail = emailValue;
                        }
                    }
                    
                    if contactEmail is string && contactEmail != "" {
                        emails[usernameToCheck] = contactEmail;
                        log:printInfo("Found email for " + usernameToCheck + ": " + contactEmail);
                        continue;
                    }
                    
                    // Try to use phone as fallback
                    string? phoneEmail = ();
                    if contactMap.hasKey("phone") {
                        var phoneValue = contactMap["phone"];
                        if phoneValue is string && phoneValue.indexOf("@") != -1 {
                            phoneEmail = phoneValue;
                        }
                    }
                    
                    if phoneEmail is string && phoneEmail != "" {
                        emails[usernameToCheck] = phoneEmail;
                        log:printInfo("Found phone email for " + usernameToCheck + ": " + phoneEmail);
                        continue;
                    }
                }
                
                // If we get here, try looking in the user collection without checking notification settings
                map<json> userFilter = {
                    "username": usernameToCheck
                };
                
                record {}|() userRecord = check mongodb:userCollection->findOne(userFilter);
                
                if userRecord is record {} {
                    json userJson = userRecord.toJson();
                    map<json> userMap = <map<json>>userJson;
                    
                    // Try to find email in phone_number field
                    string? phoneNumberEmail = ();
                    if userMap.hasKey("phone_number") {
                        var phoneValue = userMap["phone_number"];
                        if phoneValue is string && phoneValue.indexOf("@") != -1 {
                            phoneNumberEmail = phoneValue;
                        }
                    }
                    
                    if phoneNumberEmail is string && phoneNumberEmail != "" {
                        emails[usernameToCheck] = phoneNumberEmail;
                        log:printInfo("Found phone_number email for " + usernameToCheck + ": " + phoneNumberEmail);
                        continue;
                    }
                }
                
                log:printWarn("No email found for username: " + usernameToCheck);
            } on fail error e {
                log:printError("Error processing " + usernameToCheck + ": " + e.message());
                // Continue with the next username instead of returning the error
            }
        }
        
        log:printInfo("Email collection complete. Found " + emails.length().toString() + " emails");
        return emails;
    }

    function createMeetingNotification(string meetingId, string meetingTitle, MeetingType meetingType, MeetingParticipant[] participants, MeetingParticipant[]? hosts = ()) returns Notification|error {
        // Separate lists for different types of recipients
        string[] creatorAndHostRecipients = []; // For creator and hosts
        string[] participantRecipients = []; // For regular participants
        
        // Add all participants to participants list
        foreach MeetingParticipant participant in participants {
            participantRecipients.push(participant.username);
        }
        
        // Add hosts to creator/host list if it's a round_robin meeting
        if hosts is MeetingParticipant[] {
            foreach MeetingParticipant host in hosts {
                boolean alreadyExists = false;
                foreach string existingUser in creatorAndHostRecipients {
                    if (existingUser == host.username) {
                        alreadyExists = true;
                        break;
                    }
                }
                
                if (!alreadyExists) {
                    creatorAndHostRecipients.push(host.username);
                    
                    // Also remove the host from participants list if they were in it
                    int indexToRemove = -1;
                    int i = 0;
                    foreach string participant in participantRecipients {
                        if (participant == host.username) {
                            indexToRemove = i;
                            break;
                        }
                        i = i + 1;
                    }
                    
                    if (indexToRemove >= 0) {
                        participantRecipients = [...participantRecipients.slice(0, indexToRemove), ...participantRecipients.slice(indexToRemove + 1)];
                    }
                }
            }
        }
        
        // Create and send notifications based on recipient type and meeting type
        
        // First, create notification for creator and hosts (always creation type)
        if (creatorAndHostRecipients.length() > 0) {
            Notification creatorHostNotification = {
                id: uuid:createType1AsString(),
                title: meetingTitle + " Creation",
                message: "You have created or are hosting a new meeting: " + meetingTitle,
                notificationType: "creation", // Always creation type for creator/hosts
                meetingId: meetingId,
                toWhom: creatorAndHostRecipients,
                createdAt: time:utcToString(time:utcNow())
            };
            
            // Insert the notification
            _ = check mongodb:notificationCollection->insertOne(creatorHostNotification);
            
            // Handle email notifications if needed
            if creatorAndHostRecipients.length() > 0 {
                // Get the meeting details
                map<json> meetingFilter = {
                    "id": meetingId
                };
                
                record {}|() meetingRecord = check mongodb:meetingCollection->findOne(meetingFilter);
                
                if meetingRecord is record {} {
                    json meetingJson = meetingRecord.toJson();
                    Meeting meeting = check meetingJson.cloneWithType(Meeting);
                    
                    // Collect email addresses for all recipients
                    map<string> creatorEmails = check self.collectParticipantEmails(creatorAndHostRecipients);
                    
                    // Send email notifications
                    error? emailResult = self.sendEmailNotifications(creatorHostNotification, meeting, creatorEmails);
                    
                    if emailResult is error {
                        log:printError("Failed to send creation email notifications", emailResult);
                        // Continue execution even if email sending fails
                    }
                }
            }
        }
        
        // Now, create notification for participants based on meeting type
        if (participantRecipients.length() > 0) {
            string participantTitle;
            string participantMessage;
            NotificationType participantNotifType;
            
            if meetingType == "direct" {
                participantTitle = meetingTitle + " Creation";
                participantMessage = "You have been invited to a new meeting: " + meetingTitle;
                participantNotifType = "creation";
            } else if meetingType == "group" {
                participantTitle = meetingTitle + " - Please Mark Your Availability";
                participantMessage = "You have been invited to a new group meeting: \"" + meetingTitle + "\". Please mark your availability.";
                participantNotifType = "availability_request";
            } else { // round_robin
                participantTitle = meetingTitle + " - Please Mark Your Availability";
                participantMessage = "You have been invited to a new round-robin meeting: \"" + meetingTitle + "\". Please mark your availability.";
                participantNotifType = "availability_request";
            }
            
            Notification participantNotification = {
                id: uuid:createType1AsString(),
                title: participantTitle,
                message: participantMessage,
                notificationType: participantNotifType,
                meetingId: meetingId,
                toWhom: participantRecipients,
                createdAt: time:utcToString(time:utcNow())
            };
            
            // Insert the notification
            _ = check mongodb:notificationCollection->insertOne(participantNotification);
            
            // Handle email notifications if needed
            if participantRecipients.length() > 0 {
                // Get the meeting details
                map<json> meetingFilter = {
                    "id": meetingId
                };
                
                record {}|() meetingRecord = check mongodb:meetingCollection->findOne(meetingFilter);
                
                if meetingRecord is record {} {
                    json meetingJson = meetingRecord.toJson();
                    Meeting meeting = check meetingJson.cloneWithType(Meeting);
                    
                    // Collect email addresses for all recipients
                    map<string> participantEmails = check self.collectParticipantEmails(participantRecipients);
                    
                    // Send email notifications
                    error? emailResult = self.sendEmailNotifications(participantNotification, meeting, participantEmails);
                    
                    if emailResult is error {
                        log:printError("Failed to send participant email notifications", emailResult);
                        // Continue execution even if email sending fails
                    }
                }
            }
        }
        
        // Return a dummy notification - we've already inserted the actual notifications
        return {
            id: uuid:createType1AsString(),
            title: meetingTitle,
            message: "Meeting notification sent",
            notificationType: "creation",
            meetingId: meetingId,
            toWhom: [],
            createdAt: time:utcToString(time:utcNow())
        };
    }
    
    resource function post auth/signup(http:Caller caller, http:Request req) returns error? {
        // Parse the JSON payload from the request body
        json signupPayload = check req.getJsonPayload();
        
        // Log redacted payload for security (we'll omit the password entirely)
        log:printInfo("New signup request received for user: " + (signupPayload.username is string ? (check signupPayload.username).toString() : "unknown"));
        
        // Convert JSON to SignupRequest type with proper error handling
        SignupRequest signupDetails = check signupPayload.cloneWithType(SignupRequest);
        
        // Validate required fields
        if (signupDetails.username == "" || signupDetails.name == "" || signupDetails.password == "") {
            log:printError("Missing required fields for signup");
            http:Response badRequestResponse = new;
            badRequestResponse.statusCode = 400; // Bad Request status code
            badRequestResponse.setJsonPayload({"error": "Username, name, and password are required fields"});
            check caller->respond(badRequestResponse);
            return;
        }

        // Check if the user already exists in the collection using username field
        map<json> filter = {"username": signupDetails.username};
        stream<User, error?> userStream = check mongodb:userCollection->find(filter);
        record {|User value;|}? existingUser = check userStream.next();
        
        if (existingUser is record {|User value;|}) {
            log:printError("User already exists");
            http:Response conflictResponse = new;
            conflictResponse.statusCode = 409; // Conflict status code
            conflictResponse.setJsonPayload({"error": "User already exists"});
            check caller->respond(conflictResponse);
            return;
        }
        
        // Hash the password before storing
        string originalPassword = signupDetails.password;
        string hashedPassword = hashPassword(originalPassword);
        
        // Create a new User record with only the required fields
        User newUser = {
            username: signupDetails.username,
            name: signupDetails.name,
            password: hashedPassword
            // All other fields will use their default values
        };
        
        // Insert the new user into the MongoDB collection
        check mongodb:userCollection->insertOne(newUser);

        // Send a success response
        http:Response response = new;
        response.statusCode = 201; // Created status code
        response.setJsonPayload({"message": "User signed up successfully"});
        check caller->respond(response);
    }
    
    resource function post auth/login(http:Caller caller, http:Request req) returns error? {
    // Parse the JSON payload from the request body
    json loginPayload = check req.getJsonPayload();
    
    // Log the login attempt without password
    log:printInfo("Login attempt for user: " + (loginPayload.username is string ? (check loginPayload.username).toString() : "unknown"));
    
    // Convert JSON to LoginRequest type
    LoginRequest loginDetails = check loginPayload.cloneWithType(LoginRequest);
    
    // First, find the user by username
    map<json> usernameFilter = {"username": loginDetails.username};
    stream<User, error?> userStream = check mongodb:userCollection->find(usernameFilter);
    record {|User value;|}? userRecord = check userStream.next();
    
    if (userRecord is ()) {
        log:printError("Invalid username or password");
        http:Response unauthorizedResponse = new;
        unauthorizedResponse.statusCode = 401; // Unauthorized status code
        unauthorizedResponse.setJsonPayload({"error": "Invalid username or password"});
        check caller->respond(unauthorizedResponse);
        return;
    }
    
    User user = userRecord.value;
    
    // Hash the provided password and compare with stored hash
    string hashedInputPassword = hashPassword(loginDetails.password);
    
    if (hashedInputPassword != user.password) {
        log:printError("Invalid username or password");
        http:Response unauthorizedResponse = new;
        unauthorizedResponse.statusCode = 401; // Unauthorized status code
        unauthorizedResponse.setJsonPayload({"error": "Invalid username or password"});
        check caller->respond(unauthorizedResponse);
        return;
    }
    
    // Generate a new refresh token
    string refreshToken = uuid:createType1AsString();
    
    // Update the user record with the new refresh token
    map<json> filter = {"username": user.username};
    mongodb:Update updateOperation = {
        "set": {"email_refresh_token": refreshToken}
    };
    _ = check mongodb:userCollection->updateOne(filter, updateOperation);
    
    // Generate JWT token 
    string token = check self.generateJwtToken(user);
    
    // Create login response - no token in the response body
    LoginResponse loginResponse = {
        username: user.username,
        name: user.name,
        isadmin: user.isadmin,
        role: user.role,
        success: true,
        calendar_connected: user.calendar_connected
    };

    json loginResponseJson = loginResponse.toJson();
    
    // Send the response with the JWT token in HttpOnly secure cookie
    http:Response response = new;
    response.setJsonPayload(loginResponseJson);
    
        // Set the JWT token as an HttpOnly secure cookie
        http:Cookie jwtCookie = new("auth_token", token, 
            path = "/", 
            httpOnly = true, 
            secure = true,
            maxAge = 3600 // 1 hour, matching the JWT expiration
        );

        // Set the refresh token in a separate cookie with longer expiration
        http:Cookie refreshCookie = new("refresh_token", refreshToken, 
            path = "/api/auth/refresh", // Restrict to refresh endpoint only
            httpOnly = true, 
            secure = true,
            maxAge = 2592000 // 30 days
        );

        response.addCookie(jwtCookie);
        response.addCookie(refreshCookie);
        check caller->respond(response);
    }

    resource function post auth/refresh(http:Caller caller, http:Request req) returns error? {
        // Get the refresh token from the cookie
        string? refreshToken = ();
        http:Cookie[] cookies = req.getCookies();
        
        foreach http:Cookie cookie in cookies {
            if cookie.name == "refresh_token" {
                refreshToken = cookie.value;
                break;
            }
        }
        
        // If no refresh token in cookie, try to get it from the request body
        if refreshToken is () {
            json|http:ClientError jsonPayload = req.getJsonPayload();
            
            if jsonPayload is http:ClientError {
                http:Response badRequestResponse = new;
                badRequestResponse.statusCode = 400;
                badRequestResponse.setJsonPayload({"error": "Invalid request format"});
                check caller->respond(badRequestResponse);
                return;
            }
            
            RefreshTokenRequest tokenRequest = check jsonPayload.cloneWithType(RefreshTokenRequest);
            refreshToken = tokenRequest.refresh_token;
        }
        
        // Validate the refresh token exists
        if refreshToken is () || refreshToken == "" {
            http:Response unauthorizedResponse = new;
            unauthorizedResponse.statusCode = 401;
            unauthorizedResponse.setJsonPayload({"error": "Refresh token is required"});
            check caller->respond(unauthorizedResponse);
            return;
        }
        
        // Find user by refresh token
        map<json> filter = {"email_refresh_token": refreshToken};
        stream<User, error?> userStream = check mongodb:userCollection->find(filter);
        record {|User value;|}? userRecord = check userStream.next();
        
        if userRecord is () {
            // If no user found with this refresh token, try looking for Google refresh token
            map<json> googleFilter = {"refresh_token": refreshToken};
            stream<User, error?> googleUserStream = check mongodb:userCollection->find(googleFilter);
            userRecord = check googleUserStream.next();
            
            if userRecord is () {
                log:printError("Invalid refresh token");
                http:Response unauthorizedResponse = new;
                unauthorizedResponse.statusCode = 401;
                unauthorizedResponse.setJsonPayload({"error": "Invalid refresh token"});
                check caller->respond(unauthorizedResponse);
                return;
            }
        }
        
        // Safely unwrap the record since we now know it's not null
        User user;
        if userRecord is record {|User value;|} {
            user = userRecord.value;
        } else {
            // This should never happen since we checked above, but added for completeness
            log:printError("Unexpected error: userRecord is not of the expected type");
            http:Response errorResponse = new;
            errorResponse.statusCode = 500;
            errorResponse.setJsonPayload({"error": "Internal server error"});
            check caller->respond(errorResponse);
            return;
        }
        
        // Generate a new refresh token
        string newRefreshToken = uuid:createType1AsString();
        
        // Update the user record with the new refresh token
        map<json> updateFilter = {"username": user.username};
        mongodb:Update updateOperation = {
            "set": {"email_refresh_token": newRefreshToken}
        };
        _ = check mongodb:userCollection->updateOne(updateFilter, updateOperation);
        
        // Generate a new JWT token
        string newToken = check self.generateJwtToken(user);
        
        // Create the response
        http:Response response = new;
        
        // Set the new JWT token as an HttpOnly secure cookie
        http:Cookie jwtCookie = new("auth_token", newToken, 
            path = "/", 
            httpOnly = true, 
            secure = true,
            maxAge = 3600 // 1 hour, matching the JWT expiration
        );
        
        // Set the new refresh token in a separate cookie with longer expiration
        http:Cookie refreshCookie = new("refresh_token", newRefreshToken, 
            path = "/api/auth/refresh", // Restrict to refresh endpoint only
            httpOnly = true, 
            secure = true,
            maxAge = 2592000 // 30 days
        );
        
        response.addCookie(jwtCookie);
        response.addCookie(refreshCookie);
        
        // Include minimal user info in the response
        json responseBody = {
            "username": user.username,
            "name": user.name,
            "message": "Token refreshed successfully"
        };
        
        response.setJsonPayload(responseBody);
        check caller->respond(response);
    }

    
    // Updated Google login endpoint
    resource function post auth/googleLogin(http:Caller caller, http:Request req) returns error? {
        // Parse the JSON payload from the request body
        json googleLoginPayload = check req.getJsonPayload();
        
        // Log the received payload for debugging (excluding sensitive data)
        log:printInfo("Google login request for: " + (googleLoginPayload.email is string ? (check googleLoginPayload.email).toString() : "unknown"));
        
        // Convert JSON to GoogleLoginRequest type
        GoogleLoginRequest googleDetails = check googleLoginPayload.cloneWithType(GoogleLoginRequest);
        
        // Check if the user exists with the provided Google ID
        map<json> filter = {"googleid": googleDetails.googleid};
        stream<User, error?> userStream = check mongodb:userCollection->find(filter);
        record {|User value;|}? userRecord = check userStream.next();
        
        User user;
        
        if (userRecord is ()) {
            // User doesn't exist - create a new account
            // Generate a secure random password and hash it
            string randomPassword = uuid:createType1AsString();
            string hashedPassword = hashPassword(randomPassword);
            
            user = {
                username: googleDetails.email, // Using email as username
                name: googleDetails.name,      // Use the name from Google account
                password: hashedPassword,      // Store hashed random password
                googleid: googleDetails.googleid,
                profile_pic: googleDetails.picture,
                calendar_connected: false,
                refresh_token: ""
            };
            
            // Insert the new user into the MongoDB collection
            check mongodb:userCollection->insertOne(user);
            log:printInfo("New user created from Google login: " + googleDetails.email);
        } else {
            // User exists
            user = userRecord.value;
            log:printInfo("Existing user logged in via Google: " + user.username);
        }
        
        // Generate JWT token
        string token = check self.generateJwtToken(user);
        
        // Create login response - no token in the response
        LoginResponse loginResponse = {
            username: user.username,
            name: user.name,
            isadmin: user.isadmin,
            role: user.role,
            success: true,
            calendar_connected: user.calendar_connected
        };

        json loginResponseJson = loginResponse.toJson();
        
        // Send the response with the JWT token in HttpOnly secure cookie
        http:Response response = new;
        response.setJsonPayload(loginResponseJson);
        
        // Set the JWT token as an HttpOnly secure cookie
        http:Cookie jwtCookie = new("auth_token", token, 
            path = "/", 
            httpOnly = true, 
            secure = true,
            maxAge = 3600 // 1 hour, matching the JWT expiration
        );

        response.addCookie(jwtCookie);
        check caller->respond(response);
    }
    
    // Updated Google OAuth flow to include calendar permissions
    resource function get auth/google() returns http:Response|error {
        // Include calendar-related scopes in the permission request
        string encodedRedirectUri = check url:encode(googleRedirectUri, "UTF-8");
        string authUrl = string `https://accounts.google.com/o/oauth2/v2/auth?client_id=${googleClientId}&response_type=code&scope=email%20profile%20https://www.googleapis.com/auth/calendar&redirect_uri=${encodedRedirectUri}&access_type=offline&prompt=consent`;
        
        // Create a redirect response
        http:Response response = new;
        response.statusCode = 302; // Found/Redirect status code
        response.setHeader("Location", authUrl);
        return response;
    }
    
    // Updated Google OAuth callback to handle calendar integration
    resource function get auth/google/callback(http:Caller caller, http:Request req) returns error? {
        // Extract the authorization code from the query parameters
        string? code = req.getQueryParamValue("code");
        
        if (code is ()) {
            log:printError("No authorization code received from Google");
            http:Response errorResponse = new;
            errorResponse.statusCode = 400;
            errorResponse.setJsonPayload({"error": "No authorization code received"});
            check caller->respond(errorResponse);
            return;
        }
        
        // Exchange the code for tokens - Fixed URL encoding
        http:Client googleTokenClient = check new ("https://oauth2.googleapis.com");
        http:Request tokenRequest = new;
        string encodedRedirectUri = check url:encode(googleRedirectUri, "UTF-8");
        tokenRequest.setTextPayload(string `code=${code}&client_id=${googleClientId}&client_secret=${googleClientSecret}&redirect_uri=${encodedRedirectUri}&grant_type=authorization_code`, "application/x-www-form-urlencoded");
        
        http:Response tokenResponse = check googleTokenClient->post("/token", tokenRequest);
        json tokenJson = check tokenResponse.getJsonPayload();
        
        string accessToken = check tokenJson.access_token;
        
        // Store refresh token if provided (will be used for calendar API calls)
        string refreshToken = "";
        if (tokenJson.refresh_token is string) {
            refreshToken = check tokenJson.refresh_token;
            log:printInfo("Received refresh token for calendar access");
        }
        
        // Get user profile information
        http:Client googleUserClient = check new ("https://www.googleapis.com");
        
        map<string|string[]> headers = {"Authorization": "Bearer " + accessToken};
        http:Response userInfoResponse = check googleUserClient->get("/oauth2/v1/userinfo", headers);
        
        json userInfo = check userInfoResponse.getJsonPayload();
        
        string googleId = check userInfo.id;
        string email = check userInfo.email;
        string name = check userInfo.name;
        string? picture = check userInfo.picture;
        
        // Check if user already exists with this Google ID
        map<json> filter = {"googleid": googleId};
        stream<User, error?> userStream = check mongodb:userCollection->find(filter);
        record {|User value;|}? userRecord = check userStream.next();
        
        User user;
        boolean calendarConnected = false;
        
        if (userRecord is ()) {
            // Create a new user with a hashed random password
            string randomPassword = uuid:createType1AsString();
            string hashedPassword = hashPassword(randomPassword);
            
            // Attempt to verify calendar access if refresh token is available
            if (refreshToken != "") {
                calendarConnected = check self.verifyCalendarAccess(accessToken);
            }
            
            user = {
                username: email,
                name: name,
                password: hashedPassword,
                googleid: googleId,
                profile_pic: picture is string ? picture : "",
                calendar_connected: calendarConnected,
                refresh_token: refreshToken
            };
            
            check mongodb:userCollection->insertOne(user);
            log:printInfo("New user created with Google login: " + email + ", Calendar connected: " + calendarConnected.toString());
        } else {
            user = userRecord.value;
            
            // Update user with refresh token and check calendar access
            if (refreshToken != "") {
                calendarConnected = check self.verifyCalendarAccess(accessToken);
                
                // Update user record with new calendar connection status and refresh token
                map<json> userFilter = {"username": user.username};
                mongodb:Update updateDoc = {
                    "set": {
                        "calendar_connected": calendarConnected, 
                        "refresh_token": refreshToken
                    }
                };
                _ = check mongodb:userCollection->updateOne(userFilter, updateDoc);
                
                // Update local user object with new values
                user.calendar_connected = calendarConnected;
                user.refresh_token = refreshToken;
                
                log:printInfo("Updated user's calendar connection: " + user.username + ", Calendar connected: " + calendarConnected.toString());
            }
        }
        
        // Generate JWT token
        string token = check self.generateJwtToken(user);
        
        // Create HTML response with redirect
        string htmlResponse = string `
        <!DOCTYPE html>
        <html>
        <head>
            <title>Login Successful</title>
            <script>
                // Redirect to application dashboard without storing token
                // (token is managed by the HttpOnly cookie)
                window.location.href = '${frontendBaseUrl}/';
            </script>
        </head>
        <body>
            <h2>Login Successful!</h2>
            <p>Redirecting...</p>
        </body>
        </html>
        `;
        
        http:Response response = new;
        response.setTextPayload(htmlResponse);
        response.setHeader("Content-Type", "text/html");
        
        // Set the JWT token as an HttpOnly secure cookie
        http:Cookie jwtCookie = new("auth_token", token, 
            path = "/", 
            httpOnly = true, 
            secure = true,
            maxAge = 3600 // 1 hour, matching the JWT expiration
        );

        response.addCookie(jwtCookie);
        check caller->respond(response);
    }
    
    // New endpoint to connect Google Calendar separately
    resource function get auth/connectCalendar(http:Caller caller, http:Request req) returns error? {
        // First, verify user is authenticated by checking JWT in cookie
        string authToken = "";
        http:Cookie[] cookies = req.getCookies();
        
        foreach http:Cookie cookie in cookies {
            if (cookie.name == "auth_token") {
                authToken = cookie.value;
                break;
            }
        }
        
        if (authToken == "") {
            http:Response unauthorizedResponse = new;
            unauthorizedResponse.statusCode = 401;
            unauthorizedResponse.setJsonPayload({"error": "Authentication required"});
            check caller->respond(unauthorizedResponse);
            return;
        }
        
        // Validate the token
        jwt:ValidatorConfig validatorConfig = {
            issuer: "automeet",
            audience: "automeet-app",
            signatureConfig: {
                secret: JWT_SECRET
            }
        };
        jwt:Payload|jwt:Error payload = jwt:validate(authToken, validatorConfig);
        
        if (payload is jwt:Error) {
            http:Response unauthorizedResponse = new;
            unauthorizedResponse.statusCode = 401;
            unauthorizedResponse.setJsonPayload({"error": "Invalid or expired token"});
            check caller->respond(unauthorizedResponse);
            return;
        }
        
        // Extract username from validated token
        string username = "";
        if (payload is jwt:Payload) {
            // Get the username from the 'sub' field
            username = payload.sub ?: "";
        }
                
        // Include calendar-specific scopes and use the calendar redirect URI
        string encodedRedirectUri = check url:encode(googleCalendarRedirectUri, "UTF-8");
        string authUrl = string `https://accounts.google.com/o/oauth2/v2/auth?client_id=${googleClientId}&response_type=code&scope=https://www.googleapis.com/auth/calendar&redirect_uri=${encodedRedirectUri}&access_type=offline&prompt=consent&state=${username}`;
        
        // Create a redirect response to Google's OAuth page
        http:Response response = new;
        response.statusCode = 302; // Found/Redirect status code
        response.setHeader("Location", authUrl);
        check caller->respond(response);
    }
    
    // Callback endpoint specifically for calendar connection
    resource function get auth/google/calendar/callback(http:Caller caller, http:Request req) returns error? {
        // Extract authorization code and state (username) from query parameters
        string? code = req.getQueryParamValue("code");
        string? username = req.getQueryParamValue("state");
        
        if (code is () || username is ()) {
            log:printError("Missing code or username for calendar connection");
            http:Response errorResponse = new;
            errorResponse.statusCode = 400;
            errorResponse.setJsonPayload({"error": "Missing required parameters"});
            check caller->respond(errorResponse);
            return;
        }
        
        // Exchange the code for tokens using the calendar-specific redirect URI
        http:Client googleTokenClient = check new ("https://oauth2.googleapis.com");
        http:Request tokenRequest = new;
        string encodedRedirectUri = check url:encode(googleCalendarRedirectUri, "UTF-8");
        tokenRequest.setTextPayload(string `code=${code}&client_id=${googleClientId}&client_secret=${googleClientSecret}&redirect_uri=${encodedRedirectUri}&grant_type=authorization_code`, "application/x-www-form-urlencoded");
        
        http:Response tokenResponse = check googleTokenClient->post("/token", tokenRequest);
        json tokenJson = check tokenResponse.getJsonPayload();
        
        string accessToken = check tokenJson.access_token;
        
        // Get refresh token for long-term access to calendar
        string refreshToken = "";
        if (tokenJson.refresh_token is string) {
            refreshToken = check tokenJson.refresh_token;
        } else {
            log:printError("No refresh token received for calendar connection");
            http:Response errorResponse = new;
            errorResponse.statusCode = 400;
            errorResponse.setJsonPayload({"error": "Failed to get necessary permissions for calendar"});
            check caller->respond(errorResponse);
            return;
        }
        
        // Verify calendar access
        boolean calendarConnected = check self.verifyCalendarAccess(accessToken);
        
        if (!calendarConnected) {
            log:printError("Failed to verify calendar access");
            http:Response errorResponse = new;
            errorResponse.statusCode = 400;
            errorResponse.setJsonPayload({"error": "Failed to connect to Google Calendar"});
            check caller->respond(errorResponse);
            return;
        }
        
        // Update user record with calendar connection info
        map<json> userFilter = {"username": username};
        mongodb:Update updateDoc = {
            "set": {
                "calendar_connected": true, 
                "refresh_token": refreshToken
            }
        };
        
        var updateResult = mongodb:userCollection->updateOne(userFilter, updateDoc);
        
        if (updateResult is error) {
            log:printError("Failed to update user with calendar connection", updateResult);
            http:Response errorResponse = new;
            errorResponse.statusCode = 500;
            errorResponse.setJsonPayload({"error": "Failed to save calendar connection"});
            check caller->respond(errorResponse);
            return;
        }
        
        log:printInfo("Successfully connected calendar for user: " + username.toString());
        
        // Create HTML response with redirect to frontend
        string htmlResponse = string `
        <!DOCTYPE html>
        <html>
        <head>
            <title>Calendar Connected</title>
            <script>
                // Redirect to application dashboard
                window.location.href = '${frontendBaseUrl}/settings/calendarSync';
            </script>
        </head>
        <body>
            <h2>Google Calendar Connected Successfully!</h2>
            <p>Redirecting to dashboard...</p>
        </body>
        </html>
        `;
        
        http:Response response = new;
        response.setTextPayload(htmlResponse);
        response.setHeader("Content-Type", "text/html");
        check caller->respond(response);
    }
    
    // Add endpoint to check calendar connection status
    resource function get auth/calendarStatus(http:Caller caller, http:Request req) returns error? {
        // First, verify user is authenticated by checking JWT in cookie
        string authToken = "";
        http:Cookie[] cookies = req.getCookies();
        
        foreach http:Cookie cookie in cookies {
            if (cookie.name == "auth_token") {
                authToken = cookie.value;
                break;
            }
        }
        
        if (authToken == "") {
            http:Response unauthorizedResponse = new;
            unauthorizedResponse.statusCode = 401;
            unauthorizedResponse.setJsonPayload({"error": "Authentication required"});
            check caller->respond(unauthorizedResponse);
            return;
        }
        
        // Validate the token
        jwt:ValidatorConfig validatorConfig = {
            issuer: "automeet",
            audience: "automeet-app",
            signatureConfig: {
                secret: JWT_SECRET
            }
        };
        jwt:Payload|jwt:Error payload = jwt:validate(authToken, validatorConfig);
        
        if (payload is jwt:Error) {
            http:Response unauthorizedResponse = new;
            unauthorizedResponse.statusCode = 401;
            unauthorizedResponse.setJsonPayload({"error": "Invalid or expired token"});
            check caller->respond(unauthorizedResponse);
            return;
        }
        
        // Extract username from validated token
        string username = "";
        if (payload is jwt:Payload) {
            // Get the username from the 'sub' field
            username = payload.sub ?: "";
        }
        
        // Get user from database to check calendar connection status
        map<json> userFilter = {"username": username};
        stream<User, error?> userStream = check mongodb:userCollection->find(userFilter);
        record {|User value;|}? userRecord = check userStream.next();
        
        if (userRecord is ()) {
            http:Response notFoundResponse = new;
            notFoundResponse.statusCode = 404;
            notFoundResponse.setJsonPayload({"error": "User not found"});
            check caller->respond(notFoundResponse);
            return;
        }
        
        User user = userRecord.value;
        
        // Create response with calendar connection status
        CalendarConnectionResponse statusResponse = {
            connected: user.calendar_connected,
            message: user.calendar_connected ? "Google Calendar is connected" : "Google Calendar is not connected"
        };
        
        http:Response response = new;
        response.setJsonPayload(statusResponse.toJson());
        check caller->respond(response);
    }
    
    // Utility method to verify calendar access with the given access token
    function verifyCalendarAccess(string accessToken) returns boolean|error {
        // Create HTTP client for Google Calendar API
        http:Client calendarClient = check new ("https://www.googleapis.com");
        
        // Try to access the user's calendar list as a verification
        map<string|string[]> headers = {"Authorization": "Bearer " + accessToken};
        http:Response calendarResponse = check calendarClient->get("/calendar/v3/users/me/calendarList", headers);
        
        // Check if we got a successful response
        if (calendarResponse.statusCode == 200) {
            log:printInfo("Successfully verified calendar access");
            return true;
        } else {
            json errorPayload = check calendarResponse.getJsonPayload();
            log:printError("Failed to verify calendar access: " + errorPayload.toString());
            return false;
        }
    }
    
    // Add a logout endpoint to clear the cookie
    resource function get auth/logout(http:Caller caller) returns error? {
        http:Response response = new;
        
        // Log the logout attempt
        log:printInfo("User logout requested");
        
        // Create an expired cookie to clear the auth token
        http:Cookie expiredCookie = new("auth_token", "",
            path = "/", 
            httpOnly = true, 
            secure = true,
            maxAge = 0 // Immediately expire the cookie
        );

        // Add CORS headers for cross-origin requests
        response.setHeader("Access-Control-Allow-Origin", "http://localhost:3000");
        response.setHeader("Access-Control-Allow-Credentials", "true");
        
        response.addCookie(expiredCookie);
        response.setJsonPayload({"message": "Logged out successfully"});
        check caller->respond(response);
        
        log:printInfo("User logged out successfully");
    }

    // Add this new endpoint to retrieve Gmail addresses with connected calendars
    resource function get auth/connectedCalendarAccounts(http:Caller caller, http:Request req) returns error? {
        // First, verify the requesting user is authenticated and admin
        string authToken = "";
        http:Cookie[] cookies = req.getCookies();
        
        foreach http:Cookie cookie in cookies {
            if (cookie.name == "auth_token") {
                authToken = cookie.value;
                break;
            }
        }
        
        if (authToken == "") {
            http:Response unauthorizedResponse = new;
            unauthorizedResponse.statusCode = 401;
            unauthorizedResponse.setJsonPayload({"error": "Authentication required"});
            check caller->respond(unauthorizedResponse);
            return;
        }
        
        // Validate the token
        jwt:ValidatorConfig validatorConfig = {
            issuer: "automeet",
            audience: "automeet-app",
            signatureConfig: {
                secret: JWT_SECRET
            }
        };
        jwt:Payload|jwt:Error payload = jwt:validate(authToken, validatorConfig);
        
        if (payload is jwt:Error) {
            http:Response unauthorizedResponse = new;
            unauthorizedResponse.statusCode = 401;
            unauthorizedResponse.setJsonPayload({"error": "Invalid or expired token"});
            check caller->respond(unauthorizedResponse);
            return;
        }
        
        // Extract username from validated token
        string username = "";
        if (payload is jwt:Payload) {
            // Get the username from the 'sub' field
            username = payload.sub ?: "";
        }
        
        // Retrieve the user from the database to check admin status
        map<json> userFilter = {"username": username};
        stream<User, error?> adminCheckStream = check mongodb:userCollection->find(userFilter);
        record {|User value;|}? userRecord = check adminCheckStream.next();
        
        if (userRecord is ()) {
            http:Response notFoundResponse = new;
            notFoundResponse.statusCode = 404;
            notFoundResponse.setJsonPayload({"error": "User not found"});
            check caller->respond(notFoundResponse);
            return;
        }
        
        // Check if the user is an admin
        User currentUser = userRecord.value;
        if (!currentUser.isadmin) {
            http:Response forbiddenResponse = new;
            forbiddenResponse.statusCode = 403;
            forbiddenResponse.setJsonPayload({"error": "Only administrators can access this data"});
            check caller->respond(forbiddenResponse);
            return;
        }
        
        // Query MongoDB for users with connected calendars
        map<json> filter = {"calendar_connected": true};
        stream<User, error?> userStream = check mongodb:userCollection->find(filter);
        
        // Create an array to hold the emails
        json[] connectedEmails = [];
        
        // Process the stream of users
        error? e = userStream.forEach(function(User user) {
            // Add just the email (username) to the result array
            connectedEmails.push(user.username);
        });
        
        if (e is error) {
            http:Response errorResponse = new;
            errorResponse.statusCode = 500;
            errorResponse.setJsonPayload({"error": "Error retrieving connected accounts"});
            check caller->respond(errorResponse);
            return;
        }
        
        // Return the list of emails
        http:Response response = new;
        response.setJsonPayload({"connected_accounts": connectedEmails});
        check caller->respond(response);
    }

    // Disconnect calendar endpoint
    resource function post auth/disconnectCalendar(http:Caller caller, http:Request req) returns error? {
        // First, verify user is authenticated by checking JWT in cookie
        string authToken = "";
        http:Cookie[] cookies = req.getCookies();
        
        foreach http:Cookie cookie in cookies {
            if (cookie.name == "auth_token") {
                authToken = cookie.value;
                break;
            }
        }
        
        if (authToken == "") {
            http:Response unauthorizedResponse = new;
            unauthorizedResponse.statusCode = 401;
            unauthorizedResponse.setJsonPayload({"error": "Authentication required"});
            check caller->respond(unauthorizedResponse);
            return;
        }
        
        // Validate the token
        jwt:ValidatorConfig validatorConfig = {
            issuer: "automeet",
            audience: "automeet-app",
            signatureConfig: {
                secret: JWT_SECRET
            }
        };
        jwt:Payload|jwt:Error payload = jwt:validate(authToken, validatorConfig);
        
        if (payload is jwt:Error) {
            http:Response unauthorizedResponse = new;
            unauthorizedResponse.statusCode = 401;
            unauthorizedResponse.setJsonPayload({"error": "Invalid or expired token"});
            check caller->respond(unauthorizedResponse);
            return;
        }
        
        // Extract username from validated token
        string username = "";
        if (payload is jwt:Payload) {
            // Get the username from the 'sub' field
            username = payload.sub ?: "";
        }
        
        // Update user record to disconnect calendar
        map<json> userFilter = {"username": username};
        mongodb:Update updateDoc = {
            "set": {
                "calendar_connected": false, 
                "refresh_token": ""
            }
        };
        
        var updateResult = mongodb:userCollection->updateOne(userFilter, updateDoc);
        
        if (updateResult is error) {
            log:printError("Failed to disconnect calendar for user", updateResult);
            http:Response errorResponse = new;
            errorResponse.statusCode = 500;
            errorResponse.setJsonPayload({"error": "Failed to disconnect calendar"});
            check caller->respond(errorResponse);
            return;
        }
        
        log:printInfo("Successfully disconnected calendar for user: " + username);
        
        // Create response
        http:Response response = new;
        response.setJsonPayload({"message": "Calendar disconnected successfully"});
        
        check caller->respond(response);
    }
    
    // Helper method to generate JWT token with fixed customClaims
    function generateJwtToken(User user) returns string|error {
        // Create a proper map for custom claims
        map<json> _ = {
            "name": user.name,
            "role": user.role
        };
        
        // Create a proper map for custom claims
        jwt:IssuerConfig issuerConfig = {
            username: user.username,  // This sets the 'sub' field
            issuer: "automeet",
            audience: ["automeet-app"],
            expTime: <decimal>time:utcNow()[0] + 36000, // Token valid for 1 hour
            signatureConfig: {
                algorithm: jwt:HS256,
                config: JWT_SECRET
            },
            customClaims: {
                "username": user.username,  // Add this explicitly for custom access
                "name": user.name,
                "role": user.role,
                "calendar_connected": user.calendar_connected
            }
        };
        
        string|jwt:Error token = jwt:issue(issuerConfig);
        
        if (token is jwt:Error) {
            log:printError("Error generating JWT token", token);
            return error("Error generating authentication token");
        }
        
        return token;
    }
}