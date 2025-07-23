import mongodb_atlas_app.mongodb;

import ballerina/crypto;
import ballerina/http;
import ballerina/log;
import ballerina/time;
import ballerina/uuid;

// Function to hash passwords using SHA-256
function hashPassword(string password) returns string {
    byte[] hashedBytes = crypto:hashSha256(password.toBytes());
    return hashedBytes.toBase16();
}

@http:ServiceConfig {
    cors: {
        allowOrigins: ["http://localhost:3000", "https://automeet-fe.vercel.app"],
        allowCredentials: true,
        allowHeaders: ["content-type", "authorization"],
        allowMethods: ["POST", "GET", "OPTIONS", "PUT", "DELETE"],
        maxAge: 84900
    }
}


service /api on ln {

    // Updated endpoint to create a new meeting with cookie authentication
    resource function post direct/meetings(http:Request req) returns Meeting|ErrorResponse|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
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

        // Process participants with email handling
        MeetingParticipant[] participants = check processParticipantsWithEmails(
            username,
            payload.participantIds,
            meetingId,
            "direct"
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
            participants: participants,
            deadlineNotificationSent: false
        };

        MeetingAssignment meetingAssignment = {
            id: uuid:createType1AsString(),
            username: username,
            meetingId: meetingId,
            isAdmin: true
        };

        //Insert the meeting into MongoDB
        _ = check mongodb:meetingCollection->insertOne(meeting);
        _ = check mongodb:meetinguserCollection->insertOne(meetingAssignment);

        // Send emails to unregistered participants after meeting is created
        error? emailResult = sendEmailsToUnregisteredParticipants(meeting);
        if emailResult is error {
            log:printError("Failed to send emails to unregistered participants", emailResult);
            // Continue execution even if email sending fails
        }

        //Check if the meeting time is in the future
        TimeSlot _ = payload.directTimeSlot;

        // Create and insert notification for registered participants only
        Notification notification = check createMeetingNotificationWithMixedParticipants(
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
        string? username = check validateAndGetUsernameFromCookie(req);
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

        // Process participants with email handling
        MeetingParticipant[] participants = check processParticipantsWithEmails(
            username,
            payload.participantIds,
            meetingId,
            "group"
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
            participants: participants,
            deadlineNotificationSent: false
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

        // Send emails to unregistered participants after meeting is created
        error? emailResult = sendEmailsToUnregisteredParticipants(meeting);
        if emailResult is error {
            log:printError("Failed to send emails to unregistered participants", emailResult);
            // Continue execution even if email sending fails
        }

        // Store creator's availability in the availability collection
        Availability creatorAvailability = {
            id: uuid:createType1AsString(),
            username: username,
            meetingId: meetingId,
            timeSlots: payload.groupTimeSlots
        };

        _ = check mongodb:availabilityCollection->insertOne(creatorAvailability);

        // Create and insert notification for registered participants only
        Notification notification = check createMeetingNotificationWithMixedParticipants(
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
        string? username = check validateAndGetUsernameFromCookie(req);
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
        MeetingParticipant[] hosts = check processHosts(
                username,
                payload.hostIds
        );

        // Process participants with email handling
        MeetingParticipant[] participants = check processParticipantsWithEmails(
            username,
            payload.participantIds,
            meetingId,
            "round_robin"
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
            participants: participants,
            deadlineNotificationSent: false
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

        // Send emails to unregistered participants after meeting is created
        error? emailResult = sendEmailsToUnregisteredParticipants(meeting);
        if emailResult is error {
            log:printError("Failed to send emails to unregistered participants", emailResult);
            // Continue execution even if email sending fails
        }

        // Create and insert notification for registered participants only
        Notification notification = check createMeetingNotificationWithMixedParticipants(
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
    resource function post meetings/[string meetingId](http:Request req) returns json|http:Response|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
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

        // Check if meeting is already canceled
        if meeting?.status == "canceled" {
            http:Response response = new;
            response.statusCode = 400;
            response.setJsonPayload({
                message: "Meeting is already canceled"
            });
            return response;
        }

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
        
        // Add creator to users
        allUsers.push(meeting.createdBy);
        log:printInfo("Meeting creator added to notification list: " + meeting.createdBy);

        // Add participants to users
        foreach MeetingParticipant participant in meeting?.participants ?: [] {
            allUsers.push(participant.username);
            log:printInfo("Participant added to notification list: " + participant.username);
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
                    log:printInfo("Host added to notification list: " + host.username);
                }
            }
        }
        
        log:printInfo("Total users to be notified: " + allUsers.length().toString());

        // Check notification settings for all users
        // For CANCELLATION notifications, we want to send emails to ALL users regardless of their settings
        // because cancellations are critical information that should always reach participants
        foreach string userUsername in allUsers {
            // Get user's notification settings
            map<json> settingsFilter = {
                "username": userUsername
            };

            record {}|() settingsRecord = check mongodb:notificationSettingsCollection->findOne(settingsFilter);

            if settingsRecord is record {} {
                json settingsJson = settingsRecord.toJson();
                NotificationSettings settings = check settingsJson.cloneWithType(NotificationSettings);

                log:printInfo("User " + userUsername + " has notification settings - email_notifications: " + settings.email_notifications.toString());

                // For cancellation, send email regardless of user preference (critical notification)
                emailRecipients.push(userUsername);
                log:printInfo("Added " + userUsername + " to email recipients (cancellation - always send)");
            } else {
                // If no notification settings found, default to sending email notifications
                emailRecipients.push(userUsername);
                log:printInfo("Added " + userUsername + " to email recipients (no settings found, using default)");
            }
        }
        
        log:printInfo("Final email recipients count: " + emailRecipients.length().toString());

        // Update meeting status to "canceled"
        map<json> updateFilter = {
            "id": meetingId
        };
        
        mongodb:Update updateDoc = {
            set: {
                "status": "canceled",
                "canceledBy": username,
                "canceledAt": time:utcToString(time:utcNow())
            }
        };

        _ = check mongodb:meetingCollection->updateOne(updateFilter, updateDoc);

        // Create cancellation notification for ALL participants
        Notification notification = {
            id: uuid:createType1AsString(),
            title: meeting.title + " Canceled",
            message: "The meeting \"" + meeting.title + "\" has been canceled.",
            notificationType: "cancellation",
            meetingId: meetingId,
            toWhom: allUsers,
            createdAt: time:utcToString(time:utcNow()) // Add the current time as ISO string
        };

        // Insert notification for all users
        _ = check mongodb:notificationCollection->insertOne(notification);
        
        log:printInfo("Cancellation notification created for " + allUsers.length().toString() + " users");

        // Send email notifications if there are recipients
        if emailRecipients.length() > 0 {
            log:printInfo("Sending cancellation emails to " + emailRecipients.length().toString() + " recipients");
            
            // Collect email addresses for all recipients
            map<string> participantEmails = check collectParticipantEmails(emailRecipients);
            
            log:printInfo("Email addresses collected for " + participantEmails.length().toString() + " users");

            // Send email notifications
            error? emailResult = sendEmailNotifications(notification, meeting, participantEmails);

            if emailResult is error {
                log:printError("Failed to send email notifications for cancellation", emailResult);
                // Continue execution even if email sending fails
            } else {
                log:printInfo("Cancellation email sending process completed successfully");
            }
        } else {
            log:printInfo("No email recipients found for cancellation notification");
        }

        // Note: We no longer delete meeting assignments and availabilities
        // They are kept for historical purposes and the meeting status indicates it's canceled

        return {
            "status": "success",
            "message": "Meeting canceled successfully",
            "notificationsSent": allUsers.length(),
            "emailsSent": emailRecipients.length(),
            "participants": allUsers
        };
    }
  
  
  
  
    //endpoint to fetch notifications
    resource function get notifications(http:Request req) returns Notification[]|http:Response|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
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

    // Endpoint to mark all notifications as read for the authenticated user
    resource function put notifications/markallread(http:Request req) returns json|http:Response|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
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
        string? username = check validateAndGetUsernameFromCookie(req);
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

    // Endpoint to delete a single notification
    resource function delete notifications/[string notificationId](http:Request req) returns json|http:Response|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
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
        
        // Delete the notification
        _ = check mongodb:notificationCollection->deleteOne(filter);
        
        return {
            "status": "success",
            "message": "Notification deleted successfully",
            "notificationId": notificationId
        };
    }



    

    // Updated endpoint to submit availability with cookie authentication
    resource function post availability(http:Request req) returns Availability|ErrorResponse|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
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

    
    // endpoint to get availability with cookie authentication

    resource function get availability/[string meetingId](http:Request req) returns Availability[]|ErrorResponse|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
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
        string? username = check validateAndGetUsernameFromCookie(req);
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
                check checkAndFinalizeTimeSlot(meeting);
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

    // meeting content
    resource function post meetings/[string meetingId]/content(http:Request req) returns MeetingContent|ErrorResponse|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }

        // First verify that the meeting exists and get meeting details
        map<json> meetingFilter = {
            "id": meetingId
        };

        record {}|() meetingRecord = check mongodb:meetingCollection->findOne(meetingFilter);
        if meetingRecord is () {
            return {
                message: "Meeting not found",
                statusCode: 404
            };
        }

        // Convert to Meeting type
        json meetingJson = meetingRecord.toJson();
        Meeting meeting = check meetingJson.cloneWithType(Meeting);

        // Check user's role and permission
        boolean hasPermission = false;
        string userRole = "";

        // Check if user is creator
        if meeting.createdBy == username {
            hasPermission = true;
            userRole = "creator";
        }
        // Check if user is host (for round robin meetings)
        else if meeting?.hosts is MeetingParticipant[] {
            foreach MeetingParticipant host in meeting?.hosts ?: [] {
                if host.username == username {
                    hasPermission = true;
                    userRole = "host";
                    break;
                }
            }
        }
        // Check if user is participant
        else if meeting?.participants is MeetingParticipant[] {
            foreach MeetingParticipant participant in meeting?.participants ?: [] {
                if participant.username == username {
                    hasPermission = true;
                    userRole = "participant";
                    break;
                }
            }
        }

        if !hasPermission {
            return {
                message: "Unauthorized: You must be a creator, host, or participant to submit content",
                statusCode: 403
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

        SaveContentRequest payload = check jsonPayload.cloneWithType(SaveContentRequest);

        // Create new MeetingContent record
        MeetingContent newContent = {
            id: uuid:createType1AsString(),
            meetingId: meetingId,
            uploaderId: username,
            username: username,
            content: payload.content,
            createdAt: time:utcToString(time:utcNow())
        };

        // Insert into MongoDB
        _ = check mongodb:contentCollection->insertOne(newContent);

        // Log the content submission
        log:printInfo(string `Content submitted by ${username} (${userRole}) for meeting ${meetingId}`);

        return newContent;
    }

    resource function get meetings/[string meetingId]/content(http:Request req) returns MeetingContent[]|ErrorResponse|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }

        // First verify that the meeting exists and get meeting details
        map<json> meetingFilter = {
            "id": meetingId
        };

        record {}|() meetingRecord = check mongodb:meetingCollection->findOne(meetingFilter);
        if meetingRecord is () {
            return {
                message: "Meeting not found",
                statusCode: 404
            };
        }

        // Convert to Meeting type
        json meetingJson = meetingRecord.toJson();
        Meeting meeting = check meetingJson.cloneWithType(Meeting);

        // Check user's role and permission
        boolean hasPermission = false;

        // Check if user is creator
        if meeting.createdBy == username {
            hasPermission = true;
        }
        // Check if user is host (for round robin meetings)
        else if meeting?.hosts is MeetingParticipant[] {
            foreach MeetingParticipant host in meeting?.hosts ?: [] {
                if host.username == username {
                    hasPermission = true;
                    break;
                }
            }
        }
        // Check if user is participant
        else if meeting?.participants is MeetingParticipant[] {
            foreach MeetingParticipant participant in meeting?.participants ?: [] {
                if participant.username == username {
                    hasPermission = true;
                    break;
                }
            }
        }

        if !hasPermission {
            return {
                message: "Unauthorized: You must be a creator, host, or participant to view content",
                statusCode: 403
            };
        }

        // Get all content for this meeting
        map<json> contentFilter = {
            "meetingId": meetingId
        };

        stream<record {}, error?> contentCursor = check mongodb:contentCollection->find(contentFilter);
        MeetingContent[] contents = [];

        // Process the results
        check from record {} contentData in contentCursor
            do {
                json contentJson = contentData.toJson();
                MeetingContent content = check contentJson.cloneWithType(MeetingContent);
                contents.push(content);
            };

        return contents;
    }

    resource function get meeting/[string meetingId]/availabilities(http:Request req) returns ParticipantAvailability[]|http:Response|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
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
                map<json> availJsonMap = <map<json>>availJson;

                // Add submittedAt if not present
                if !availJsonMap.hasKey("submittedAt") {
                    availJsonMap["submittedAt"] = time:utcToString(time:utcNow());
                }

                ParticipantAvailability avail = check availJsonMap.cloneWithType(ParticipantAvailability);
                availabilities.push(avail);
            };

        // Check if there's a best time slot found for this meeting
        map<json> bestTimeSlotFilter = {
            "meetingId": meetingId
        };

        record {}|() bestTimeSlotRecord = check mongodb:bestTimeSlotCollection->findOne(bestTimeSlotFilter);

        // If there's a best time slot, mark the corresponding time slots
        if (bestTimeSlotRecord is record {}) {
            json bestTimeSlotJson = bestTimeSlotRecord.toJson();
            BestTimeSlot bestTimeSlotData = check bestTimeSlotJson.cloneWithType(BestTimeSlot);
            TimeSlot bestTimeSlot = bestTimeSlotData.timeSlot;

            // Mark the best time slot in each participant's availability
            foreach int i in 0 ..< availabilities.length() {
                TimeSlot[] timeSlots = availabilities[i].timeSlots;
                TimeSlot[] updatedTimeSlots = [];

                foreach TimeSlot slot in timeSlots {
                    // Create a copy of the time slot
                    TimeSlot updatedSlot = {
                        startTime: slot.startTime,
                        endTime: slot.endTime,
                        isBestTimeSlot: false
                    };

                    // Check if this is the best time slot
                    if (slot.startTime == bestTimeSlot.startTime &&
                        slot.endTime == bestTimeSlot.endTime) {
                        // Mark this as the best time slot
                        updatedSlot.isBestTimeSlot = true;
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
                "bestTimeSlot": bestTimeSlotData.toJson(),
                "hasBestTimeSlot": true
            });
            return enhancedResponse;
        }

        // If no best time slot was found, return just the availabilities array
        return availabilities;
    }

    resource function put participant/availability(http:Request req) returns ParticipantAvailability|http:Response|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
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

        if (meetingData.meetingType == "round_robin") {
            // Check if the user is a host
            boolean isHost = false;
            if meetingData?.hosts is MeetingParticipant[] {
                foreach MeetingParticipant host in meetingData?.hosts ?: [] {
                    if host.username == username {
                        isHost = true;
                        break;
                    }
                }
            }
            
            if isHost {
                check checkAndNotifyParticipantsForRoundRobin(meetingData);
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
        json[] timeSlotJsonArray = payload.timeSlots.map(function(TimeSlot slot) returns json {
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
            check checkAndNotifyParticipantsForRoundRobin(meetingData);
        }

        // Check for 80% participant availability threshold and find best time slot
        if (meetingData.meetingType == "group" || meetingData.meetingType == "round_robin") {
            check checkParticipantAvailabilityAndFindBestSlot(meetingData);
        }

        // For any meeting type, check if deadline has passed and find the best time slot
        check checkAndFinalizeTimeSlot(meetingData);

        return payload;
    }

    // Endpoint to get participant availability for a meeting (with username filter)
    resource function get participant/availability/[string meetingId](http:Request req) returns ParticipantAvailability[]|http:Response|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
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
                map<json> availJsonMap = <map<json>>availJson;

                // Add submittedAt if not present
                if !availJsonMap.hasKey("submittedAt") {
                    availJsonMap["submittedAt"] = time:utcToString(time:utcNow());
                }

                ParticipantAvailability avail = check availJsonMap.cloneWithType(ParticipantAvailability);
                availabilities.push(avail);
            };

        // Check for best time slot in bestTimeSlotCollection for all users
        map<json> bestTimeSlotFilter = {
            "meetingId": meetingId
        };

        record {}|() bestTimeSlotRecord = check mongodb:bestTimeSlotCollection->findOne(bestTimeSlotFilter);

        // If there's a best time slot, include it in the response
        if (bestTimeSlotRecord is record {}) {
            json bestTimeSlotJson = bestTimeSlotRecord.toJson();
            json timeSlotJson = check bestTimeSlotJson.timeSlot;

            // Create enhanced response with best time slot metadata
            json availabilitiesJson = check availabilities.toJson().cloneWithType(json);

            map<json> responseJson = {
                "availabilities": availabilitiesJson,
                "bestTimeSlot": timeSlotJson,
                "hasBestTimeSlot": true
            };

            http:Response enhancedResponse = new;
            enhancedResponse.setJsonPayload(responseJson);
            return enhancedResponse;
        }

        // If no best time slot found, return regular availabilities array
        return availabilities;
    }

    resource function put notification/settings(http:Request req) returns NotificationSettings|ErrorResponse|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
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
        string? username = check validateAndGetUsernameFromCookie(req);
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

    // Endpoint to confirm a suggested meeting time
    resource function post meetings/[string meetingId]/confirm(http:Request req) returns json|http:Response|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
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
            // Get the best time slot from best time slot collection if no timeSlot provided
            map<json> bestTimeSlotFilter = {
                "meetingId": meetingId
            };

            record {}|() bestTimeSlotRecord = check mongodb:bestTimeSlotCollection->findOne(bestTimeSlotFilter);

            if bestTimeSlotRecord is () {
                http:Response response = new;
                response.statusCode = 404;
                response.setJsonPayload({
                    message: "No best time slot found for this meeting and no time slot provided"
                });
                return response;
            }

            json bestTimeSlotJson = (<record {}>bestTimeSlotRecord).toJson();
            json timeSlotJson = check bestTimeSlotJson.timeSlot;
            timeSlot = check timeSlotJson.cloneWithType(TimeSlot);
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
            message: "The meeting \"" + meeting.title + "\" has been confirmed.",
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
            // For CONFIRMATION notifications, we want to send emails to ALL users regardless of their settings
            // because confirmations are important information that should always reach participants
            emailRecipients.push(recipient);
            log:printInfo("Added " + recipient + " to email recipients (confirmation - always send)");
        }

        if emailRecipients.length() > 0 {
            log:printInfo("Sending confirmation emails to " + emailRecipients.length().toString() + " recipients");
            
            // Update meeting object for email notification
            meeting.directTimeSlot = timeSlot;
            meeting.status = "confirmed";

            // Collect email addresses
            map<string> participantEmails = check collectParticipantEmails(emailRecipients);

            // Send email notifications
            error? emailResult = sendEmailNotifications(notification, meeting, participantEmails);

            if emailResult is error {
                log:printError("Failed to send email notifications for confirmation", emailResult);
                // Continue execution even if email sending fails
            } else {
                log:printInfo("Confirmation email sending process completed successfully");
            }
        } else {
            log:printInfo("No email recipients found for confirmation notification");
        }

        // Clean up the temporary suggestion and best time slot records
        map<json> suggestedTimeFilter = {
            "meetingId": meetingId
        };
        _ = check mongodb:temporarySuggestionsCollection->deleteOne(suggestedTimeFilter);
        
        // Also clean up best time slot record after confirmation
        map<json> bestTimeSlotFilter = {
            "meetingId": meetingId
        };
        _ = check mongodb:bestTimeSlotCollection->deleteOne(bestTimeSlotFilter);

        return {
            "status": "success",
            "message": "Meeting time confirmed successfully",
            "timeSlot": timeSlot.toJson()
        };
    }

    // Updated endpoint to get meetings with cookie authentication
    resource function get meetings(http:Request req) returns Meeting[]|ErrorResponse|error {
    // Extract username from cookie
    string? username = check validateAndGetUsernameFromCookie(req);
    if username is () {
        return {
            message: "Unauthorized: Invalid or missing authentication token",
            statusCode: 401
        };
    }

    Meeting[] meetings = [];
    map<string> meetingIds = {}; // To track already added meetings

    // 1. Find meetings created by this user (excluding canceled ones)
    map<json> createdByFilter = {
        "createdBy": username,
        "status": {"$ne": "canceled"}  // Exclude canceled meetings
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

    // 2. Find meetings where user is a participant (excluding canceled ones)
    map<json> participantFilter = {
        "participants": {
            "$elemMatch": {
                "username": username
            }
        },
        "status": {"$ne": "canceled"}  // Exclude canceled meetings
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

    // 3. Find meetings where user is a host (excluding canceled ones)
    map<json> hostFilter = {
        "hosts": {
            "$elemMatch": {
                "username": username
            }
        },
        "status": {"$ne": "canceled"}  // Exclude canceled meetings
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
        string? username = check validateAndGetUsernameFromCookie(req);
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
        string? username = check validateAndGetUsernameFromCookie(req);
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
                    MeetingParticipant[] newParticipants = check processParticipants(username, participantIdList);

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
                        MeetingParticipant[] newHosts = check processHosts(username, hostIdList);

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

    // create notes related to a meeting
    resource function post meetings/[string meetingId]/notes(http:Request req) returns Note|ErrorResponse|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }

        // Verify meeting exists and user has access
        map<json> meetingFilter = {
            "id": meetingId
        };

        record {}|() meetingRecord = check mongodb:meetingCollection->findOne(meetingFilter);
        if meetingRecord is () {
            return {
                message: "Meeting not found",
                statusCode: 404
            };
        }

        // Convert to Meeting type
        json meetingJson = meetingRecord.toJson();
        Meeting meeting = check meetingJson.cloneWithType(Meeting);

        // Check user's permission
        boolean hasPermission = false;

        // Check if user is creator
        if meeting.createdBy == username {
            hasPermission = true;
        }
        // Check if user is host
        else if meeting?.hosts is MeetingParticipant[] {
            foreach MeetingParticipant host in meeting?.hosts ?: [] {
                if host.username == username {
                    hasPermission = true;
                    break;
                }
            }
        }
        // Check if user is participant
        else if meeting?.participants is MeetingParticipant[] {
            foreach MeetingParticipant participant in meeting?.participants ?: [] {
                if participant.username == username {
                    hasPermission = true;
                    break;
                }
            }
        }

        if !hasPermission {
            return {
                message: "Unauthorized: You must be a creator, host, or participant to create notes",
                statusCode: 403
            };
        }

        // Parse request payload
        json|http:ClientError jsonPayload = req.getJsonPayload();
        if jsonPayload is http:ClientError {
            return {
                message: "Invalid request payload",
                statusCode: 400
            };
        }

        // Validate note content
        map<json> payload = <map<json>>jsonPayload;
        if !payload.hasKey("noteContent") || payload.noteContent == "" {
            return {
                message: "Note content is required",
                statusCode: 400
            };
        }

        string currentTime = time:utcToString(time:utcNow());

        // Create note record
        Note note = {
            id: uuid:createType1AsString(),
            username: username,
            meetingId: meetingId,
            noteContent: check payload.noteContent.ensureType(),
            createdAt: currentTime,
            updatedAt: currentTime
        };

        // Insert into MongoDB
        _ = check mongodb:noteCollection->insertOne(note);

        return note;
    }
  


    // get notes related to a meeting and logged in user
    resource function get meetings/[string meetingId]/notes(http:Request req) returns Note[]|ErrorResponse|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }

        // Verify meeting exists and user has access
        map<json> meetingFilter = {
            "id": meetingId
        };

        record {}|() meetingRecord = check mongodb:meetingCollection->findOne(meetingFilter);
        if meetingRecord is () {
            return {
                message: "Meeting not found",
                statusCode: 404
            };
        }

        // Convert to Meeting type
        json meetingJson = meetingRecord.toJson();
        Meeting meeting = check meetingJson.cloneWithType(Meeting);

        // Check user's permission
        boolean hasPermission = false;

        // Check if user is creator
        if meeting.createdBy == username {
            hasPermission = true;
        }
        // Check if user is host
        else if meeting?.hosts is MeetingParticipant[] {
            foreach MeetingParticipant host in meeting?.hosts ?: [] {
                if host.username == username {
                    hasPermission = true;
                    break;
                }
            }
        }
        // Check if user is participant
        else if meeting?.participants is MeetingParticipant[] {
            foreach MeetingParticipant participant in meeting?.participants ?: [] {
                if participant.username == username {
                    hasPermission = true;
                    break;
                }
            }
        }

        if !hasPermission {
            return {
                message: "Unauthorized: You must be a creator, host, or participant to view notes",
                statusCode: 403
            };
        }

        // Get all notes for this meeting
        map<json> noteFilter = {
            "meetingId": meetingId
        };

        stream<record {}, error?> noteCursor = check mongodb:noteCollection->find(noteFilter);
        Note[] notes = [];

        // Process the results
        check from record {} noteData in noteCursor
            do {
                json noteJson = noteData.toJson();
                Note note = check noteJson.cloneWithType(Note);
                notes.push(note);
            };

        return notes;
    }

    // Add to MeetingService.bal in the service
    resource function delete meetings/notes/[string noteId](http:Request req) returns json|http:Response|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }

        // Get the note to verify it exists and check ownership
        map<json> noteFilter = {
            "id": noteId
        };

        record {}|() noteRecord = check mongodb:noteCollection->findOne(noteFilter);
        if noteRecord is () {
            return {
                message: "Note not found",
                statusCode: 404
            };
        }

        // Convert to Note type
        json noteJson = noteRecord.toJson();
        Note note = check noteJson.cloneWithType(Note);

        // Verify ownership - only the creator of the note can delete it
        if note.username != username {
            return {
                message: "Unauthorized: You can only delete your own notes",
                statusCode: 403
            };
        }

        // Delete the note
        _ = check mongodb:noteCollection->deleteOne(noteFilter);

        return {
            "message": "Note deleted successfully",
            "noteId": noteId
        };
    }

    // Endpoint for participants to submit availability (different from hosts)
    resource function post participant/availability(http:Request req) returns ParticipantAvailability|ErrorResponse|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
        if username is () {
            log:printError("POST /participant/availability: Authentication failed - no valid username from cookie");
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }

        log:printInfo(string `POST /participant/availability: Starting participant availability submission for user: ${username}`);

        // Parse the request payload
        json|http:ClientError jsonPayload = req.getJsonPayload();
        if jsonPayload is http:ClientError {
            log:printError(string `POST /participant/availability: Invalid payload for user ${username}: ${jsonPayload.message()}`);
            return {
                message: "Invalid request payload: " + jsonPayload.message(),
                statusCode: 400
            };
        }

        log:printInfo(string `POST /participant/availability: Successfully parsed payload for user ${username}`);
        log:printInfo(string `POST /participant/availability: Raw payload: ${jsonPayload.toString()}`);

        ParticipantAvailability payload = check jsonPayload.cloneWithType(ParticipantAvailability);

        // Ensure the username in the payload matches the authenticated user
        payload.username = username;

        // Generate an ID if not provided
        if (payload.id == "") {
            payload.id = uuid:createType1AsString();
            log:printInfo(string `POST /participant/availability: Generated new participant availability ID: ${payload.id} for user ${username}`);
        } else {
            log:printInfo(string `POST /participant/availability: Using provided participant availability ID: ${payload.id} for user ${username}`);
        }

        log:printInfo(string `POST /participant/availability: Participant availability payload details - MeetingId: ${payload.meetingId}, Username: ${payload.username}, TimeSlots count: ${payload.timeSlots.length()}`);

        // Log time slots details
        foreach int i in 0 ..< payload.timeSlots.length() {
            TimeSlot slot = payload.timeSlots[i];
            log:printInfo(string `POST /participant/availability: TimeSlot ${i + 1} - Start: ${slot.startTime}, End: ${slot.endTime}`);
        }

        // Check if the meeting exists
        map<json> meetingFilter = {
            "id": payload.meetingId
        };

        log:printInfo(string `POST /participant/availability: Checking if meeting exists with ID: ${payload.meetingId}`);

        record {}|() meetingRecord = check mongodb:meetingCollection->findOne(meetingFilter);
        if meetingRecord is () {
            log:printError(string `POST /participant/availability: Meeting not found with ID: ${payload.meetingId} for user ${username}`);
            return {
                message: "Meeting not found",
                statusCode: 404
            };
        }

        log:printInfo(string `POST /participant/availability: Meeting found with ID: ${payload.meetingId}`);

        // Convert to Meeting type
        json meetingJson = meetingRecord.toJson();
        Meeting meeting = check meetingJson.cloneWithType(Meeting);

        log:printInfo(string `POST /participant/availability: Meeting details - Type: ${meeting.meetingType}, Creator: ${meeting.createdBy}, Title: ${meeting.title}`);

        // Verify user's role in the meeting (must be participant)
        boolean isParticipant = false;

        // Check if user is in the participants list
        if (meeting?.participants is MeetingParticipant[]) {
            MeetingParticipant[] participants = <MeetingParticipant[]>meeting?.participants;
            log:printInfo(string `POST /participant/availability: Checking participants list (${participants.length()} participants)`);
            foreach MeetingParticipant participant in meeting?.participants ?: [] {
                log:printInfo(string `POST /participant/availability: Checking participant: ${participant.username}`);
                if (participant.username == username) {
                    isParticipant = true;
                    log:printInfo(string `POST /participant/availability: User ${username} found in participants list`);
                    break;
                }
            }
        } else {
            log:printInfo(string `POST /participant/availability: No participants list found in meeting or participants list is empty`);
        }

        if (!isParticipant) {
            log:printError(string `POST /participant/availability: User ${username} is not authorized - not a participant of meeting ${payload.meetingId}`);
            return {
                message: "Unauthorized: Only meeting participants can submit availability via this endpoint",
                statusCode: 403
            };
        }

        log:printInfo(string `POST /participant/availability: User ${username} authorized as participant for meeting ${payload.meetingId}`);

        // Check if availability already exists for this user and meeting in PARTICIPANT AVAILABILITY COLLECTION
        map<json> availFilter = {
            "username": username,
            "meetingId": payload.meetingId
        };

        log:printInfo(string `POST /participant/availability: Checking for existing availability in participantAvailabilityCollection for user ${username} and meeting ${payload.meetingId}`);

        record {}|() existingAvailability = check mongodb:participantAvailabilityCollection->findOne(availFilter);

        if existingAvailability is () {
            log:printInfo(string `POST /participant/availability: No existing availability found - will INSERT new record in participantAvailabilityCollection`);
            
            // Insert new availability into PARTICIPANT AVAILABILITY COLLECTION
            var insertResult = mongodb:participantAvailabilityCollection->insertOne(payload);
            
            if insertResult is error {
                log:printError(string `POST /participant/availability: CRITICAL ERROR - Failed to insert participant availability for ${username}: ${insertResult.message()}`);
                return {
                    message: "Failed to save availability: " + insertResult.message(),
                    statusCode: 500
                };
            } else {
                log:printInfo(string `POST /participant/availability: Successfully INSERTED new participant availability for ${username}`);
                log:printInfo(string `POST /participant/availability: Insert operation completed successfully`);
            }
        } else {
            log:printInfo(string `POST /participant/availability: Existing availability found - will UPDATE existing record in participantAvailabilityCollection`);
            
            // Update existing availability in PARTICIPANT AVAILABILITY COLLECTION
            mongodb:Update updateOperation = {
                "set": {"timeSlots": <json>payload.timeSlots}
            };
            
            var updateResult = mongodb:participantAvailabilityCollection->updateOne(availFilter, updateOperation);
            
            if updateResult is error {
                log:printError(string `POST /participant/availability: CRITICAL ERROR - Failed to update participant availability for ${username}: ${updateResult.message()}`);
                return {
                    message: "Failed to update availability: " + updateResult.message(),
                    statusCode: 500
                };
            } else {
                mongodb:UpdateResult result = <mongodb:UpdateResult>updateResult;
                log:printInfo(string `POST /participant/availability: Successfully UPDATED participant availability for ${username}`);
                log:printInfo(string `POST /participant/availability: Update result - Modified count: ${result.modifiedCount}`);
            }
        }

        // After participant submits availability, check for 80% threshold and find best time slot
        if (meeting.meetingType == "group" || meeting.meetingType == "round_robin") {
            log:printInfo(string `POST /participant/availability: Checking for 80% threshold and best time slot for ${meeting.meetingType} meeting`);
            
            // Use do-on-fail for proper error handling
            do {
                check checkParticipantAvailabilityAndFindBestSlot(meeting);
                log:printInfo(string `POST /participant/availability: Successfully checked participant availability threshold for meeting ${meeting.id}`);
            } on fail error e {
                log:printError(string `POST /participant/availability: Error in checkParticipantAvailabilityAndFindBestSlot: ${e.message()}`);
            }
        }

        log:printInfo(string `POST /participant/availability: Successfully completed participant availability submission for ${username} on meeting ${payload.meetingId}`);

        return payload;
    }

    // endpoint to cancel meetings (DELETE method)
    resource function delete meetings/[string meetingId](http:Request req) returns json|http:Response|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
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
            map<string> participantEmails = check collectParticipantEmails(emailRecipients);

            // Send email notifications
            error? emailResult = sendEmailNotifications(notification, meeting, participantEmails);

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

    resource function post availability/externally(http:Request req) returns Availability|ErrorResponse|error {
        // Parse the request payload
        json|http:ClientError jsonPayload = req.getJsonPayload();
        if jsonPayload is http:ClientError {
            return {
                message: "Invalid request payload: " + jsonPayload.message(),
                statusCode: 400
            };
        }

        ExternalAvailabilityRequest payload = check jsonPayload.cloneWithType(ExternalAvailabilityRequest);

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

        // Create new availability record
        Availability availability = {
            id: uuid:createType1AsString(),
            username: payload.userId, // Use the provided userId as username
            meetingId: payload.meetingId,
            timeSlots: payload.timeSlots
        };

        // Check if availability already exists
        map<json> availFilter = {
            "username": payload.userId,
            "meetingId": payload.meetingId
        };

        record {}|() existingAvailability = check mongodb:participantAvailabilityCollection->findOne(availFilter);

        if existingAvailability is () {
            // Insert new availability
            _ = check mongodb:participantAvailabilityCollection->insertOne(availability);
        } else {
            return {
                message: "Availability already exists for this user and meeting",
                statusCode: 409
            };
        }

        return availability;
    }

    resource function put availability/externally(http:Request req) returns Availability|ErrorResponse|error {
        // Parse the request payload
        json|http:ClientError jsonPayload = req.getJsonPayload();
        if jsonPayload is http:ClientError {
            return {
                message: "Invalid request payload: " + jsonPayload.message(),
                statusCode: 400
            };
        }

        ExternalAvailabilityRequest payload = check jsonPayload.cloneWithType(ExternalAvailabilityRequest);

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

        // Check if availability exists
        map<json> availFilter = {
            "username": payload.userId,
            "meetingId": payload.meetingId
        };

        record {}|() existingAvailability = check mongodb:participantAvailabilityCollection->findOne(availFilter);

        if existingAvailability is () {
            return {
                message: "Availability not found for this user and meeting",
                statusCode: 404
            };
        }

        // Update the availability
        mongodb:Update updateOperation = {
            "set": {
                "timeSlots": check payload.timeSlots.cloneWithType(json) // Convert TimeSlot[] to json
            }
        };

        _ = check mongodb:participantAvailabilityCollection->updateOne(availFilter, updateOperation);

        // Return the updated availability
        Availability updatedAvailability = {
            id: (existingAvailability["id"]).toString(),
            username: payload.userId,
            meetingId: payload.meetingId,
            timeSlots: payload.timeSlots
        };

        return updatedAvailability;
    }

    // External endpoint to get participant availability for a meeting
    resource function get participant/availability/externally/[string userId]/[string meetingId]() returns ParticipantAvailability|ErrorResponse|error {
        // Check if the meeting exists
        map<json> meetingFilter = {
            "id": meetingId
        };

        record {}|() meeting = check mongodb:meetingCollection->findOne(meetingFilter);
        if meeting is () {
            return {
                message: "Meeting not found",
                statusCode: 404
            };
        }

        // Create a filter to find availability for this specific user and meeting
        map<json> filter = {
            "username": userId,
            "meetingId": meetingId
        };

        // Query the participant availability collection
        record {}|() availabilityRecord = check mongodb:participantAvailabilityCollection->findOne(filter);
        
        if availabilityRecord is () {
            return {
                message: "No availability found for this user and meeting",
                statusCode: 404
            };
        }

        // Convert to ParticipantAvailability type and add required fields
        json availJson = availabilityRecord.toJson();
        map<json> availJsonMap = <map<json>>availJson;

        // Add submittedAt if not present
        if !availJsonMap.hasKey("submittedAt") {
            availJsonMap["submittedAt"] = time:utcToString(time:utcNow());
        }

        ParticipantAvailability availability = check availJsonMap.cloneWithType(ParticipantAvailability);
        return availability;
    }

    // Public endpoint to get basic meeting details without authentication
    resource function get meetings/externally/[string meetingId]() returns ExternalMeeting|ErrorResponse|error {
        // Create a filter to find the meeting by ID
        map<json> filter = {
            "id": meetingId
        };

        // Query the meeting
        record {}|() rawMeeting = check mongodb:meetingCollection->findOne(filter);

        if rawMeeting is () {
            return {
                message: "Meeting not found",
                statusCode: 404
            };
        }

        // Convert to Meeting type first
        json meetingJson = rawMeeting.toJson();
        Meeting fullMeeting = check meetingJson.cloneWithType(Meeting);

        // Create ExternalMeeting response with duration
        ExternalMeeting externalMeeting = {
            title: fullMeeting.title,
            location: fullMeeting.location,
            description: fullMeeting.description,
            createdBy: fullMeeting.createdBy,
            hosts: fullMeeting?.hosts,
            participants: fullMeeting?.participants ?: [],
            meetingType: fullMeeting.meetingType
        };

        // Add duration based on meeting type
        if fullMeeting.meetingType == "group" {
            externalMeeting.duration = fullMeeting?.groupDuration ?: "";
        } else if fullMeeting.meetingType == "round_robin" {
            externalMeeting.duration = fullMeeting?.roundRobinDuration ?: "";
        }

        return externalMeeting;
    }
  
}
