import ballerina/http;
import ballerina/log;
import ballerina/jwt;
import mongodb_atlas_app.mongodb;

// UserPayload type definition
public type UserPayload record {
    string id;
    string username;
    string email?;
    int iat?;
    int exp?;
};

@http:ServiceConfig {
    cors: {
        allowOrigins: ["http://localhost:3000", "http://localhost:5173"],
        allowCredentials: true,
        allowHeaders: ["content-type", "authorization"],
        allowMethods: ["POST", "GET", "OPTIONS", "PUT", "DELETE"],
        maxAge: 84900
    }
}

service /api/calendar on ln {

    // Create Google Calendar event
    resource function post createEvent(http:Request req) returns CalendarEventResponse|error {
        // Extract JWT token from cookies
        string? jwtToken = check getJWTFromCookies(req);
        if jwtToken is () {
            return {
                success: false,
                message: "Authentication required"
            };
        }

        UserPayload|error userPayload = validateJWT(jwtToken);
        if userPayload is error {
            return {
                success: false,
                message: "Invalid authentication token"
            };
        }

        // Parse the request payload
        json payload = check req.getJsonPayload();

        // Get user data
        map<json> userFilter = {"username": userPayload.username};
        record {}|() userRecord = check mongodb:userCollection->findOne(userFilter);
        if userRecord is () {
            return {
                success: false,
                message: "User not found"
            };
        }

        // Convert to User type
        json userJson = userRecord.toJson();
        User user = check userJson.cloneWithType(User);

        if !user.calendar_connected || user.refresh_token == "" {
            return {
                success: false,
                message: "Calendar not connected. Please connect your calendar first."
            };
        }

        // Get fresh access token
        string|error accessToken = getAccessTokenFromRefreshToken(user.refresh_token);
        if accessToken is error {
            return {
                success: false,
                message: "Failed to get calendar access. Please reconnect your calendar."
            };
        }

        // Create calendar event
        string|error eventId = createGoogleCalendarEvent(accessToken, payload);
        if eventId is error {
            return {
                success: false,
                message: "Failed to create calendar event: " + eventId.message()
            };
        }

        // Update meeting record with calendar event ID if meeting ID is provided
        // Note: Skip meeting record update for now to avoid JSON access complexity

        return {
            success: true,
            eventId: eventId,
            message: "Calendar event created successfully"
        };
    }

    // Update existing calendar event
    resource function put updateEvent/[string eventId](http:Request req) returns CalendarEventResponse|error {
        string? jwtToken = check getJWTFromCookies(req);
        if jwtToken is () {
            return {
                success: false,
                message: "Authentication required"
            };
        }

        UserPayload|error userPayload = validateJWT(jwtToken);
        if userPayload is error {
            return {
                success: false,
                message: "Invalid authentication token"
            };
        }

        // Get user data
        map<json> userFilter = {"username": userPayload.username};
        record {}|() userRecord = check mongodb:userCollection->findOne(userFilter);
        if userRecord is () {
            return {
                success: false,
                message: "User not found"
            };
        }

        // Convert to User type
        json userJson = userRecord.toJson();
        User user = check userJson.cloneWithType(User);

        if !user.calendar_connected || user.refresh_token == "" {
            return {
                success: false,
                message: "Calendar not connected. Please connect your calendar first."
            };
        }

        // Get fresh access token
        string|error accessToken = getAccessTokenFromRefreshToken(user.refresh_token);
        if accessToken is error {
            return {
                success: false,
                message: "Failed to get calendar access. Please reconnect your calendar."
            };
        }

        // Get event data from request
        json payload = check req.getJsonPayload();
        
        // Update Google Calendar event
        string|error updateResult = updateGoogleCalendarEvent(accessToken, eventId, payload);
        if updateResult is error {
            return {
                success: false,
                message: "Failed to update calendar event: " + updateResult.message()
            };
        }

        return {
            success: true,
            eventId: eventId,
            message: "Calendar event updated successfully"
        };
    }

    // Delete calendar event
    resource function delete deleteEvent/[string eventId](http:Request req) returns CalendarEventResponse|error {
        string? jwtToken = check getJWTFromCookies(req);
        if jwtToken is () {
            return {
                success: false,
                message: "Authentication required"
            };
        }

        UserPayload|error userPayload = validateJWT(jwtToken);
        if userPayload is error {
            return {
                success: false,
                message: "Invalid authentication token"
            };
        }

        // Get user data
        map<json> userFilter = {"username": userPayload.username};
        record {}|() userRecord = check mongodb:userCollection->findOne(userFilter);
        if userRecord is () {
            return {
                success: false,
                message: "User not found"
            };
        }

        // Convert to User type
        json userJson = userRecord.toJson();
        User user = check userJson.cloneWithType(User);

        if !user.calendar_connected || user.refresh_token == "" {
            return {
                success: false,
                message: "Calendar not connected. Please connect your calendar first."
            };
        }

        // Get fresh access token
        string|error accessToken = getAccessTokenFromRefreshToken(user.refresh_token);
        if accessToken is error {
            return {
                success: false,
                message: "Failed to get calendar access. Please reconnect your calendar."
            };
        }

        // Delete Google Calendar event
        error? deleteResult = deleteGoogleCalendarEvent(accessToken, eventId);
        if deleteResult is error {
            return {
                success: false,
                message: "Failed to delete calendar event: " + deleteResult.message()
            };
        }

        // Remove calendar event ID from meeting record
        map<string> meetingFilter = {
            "google_calendar_event_id": eventId
        };
        
        mongodb:Update updateDoc = {
            "unset": {
                "google_calendar_event_id": 1
            }
        };
        
        var updateResult = mongodb:meetingCollection->updateOne(meetingFilter, updateDoc);
        if updateResult is error {
            log:printError("Failed to remove calendar event ID from meeting", updateResult);
            // Don't return error here as the calendar event was deleted successfully
        }

        return {
            success: true,
            eventId: eventId,
            message: "Calendar event deleted successfully"
        };
    }

    // Sync existing meetings with Google Calendar
    resource function post syncExistingMeetings(http:Request req) returns CalendarEventResponse|error {
        string? jwtToken = check getJWTFromCookies(req);
        if jwtToken is () {
            return {
                success: false,
                message: "Authentication required"
            };
        }

        UserPayload|error userPayload = validateJWT(jwtToken);
        if userPayload is error {
            return {
                success: false,
                message: "Invalid authentication token"
            };
        }

        // Get user data
        map<json> userFilter = {"username": userPayload.username};
        record {}|() userRecord = check mongodb:userCollection->findOne(userFilter);
        if userRecord is () {
            return {
                success: false,
                message: "User not found"
            };
        }

        // Convert to User type
        json userJson = userRecord.toJson();
        User user = check userJson.cloneWithType(User);

        if !user.calendar_connected || user.refresh_token == "" {
            return {
                success: false,
                message: "Calendar not connected. Please connect your calendar first."
            };
        }

        // Get fresh access token
        string|error accessToken = getAccessTokenFromRefreshToken(user.refresh_token);
        if accessToken is error {
            return {
                success: false,
                message: "Failed to get calendar access. Please reconnect your calendar."
            };
        }

        // Get all meetings for this user that don't have calendar events
        // Try multiple possible field names and user identifiers
        map<json> meetingFilter = {
            "createdBy": userPayload.username,
            "google_calendar_event_id": {"$exists": false}
        };

        log:printInfo("Searching for meetings with createdBy filter: " + meetingFilter.toString());
        log:printInfo("Username from JWT: " + userPayload.username);

        stream<Meeting, error?> meetingStream = check mongodb:meetingCollection->find(meetingFilter);
        Meeting[] meetings = check from Meeting meeting in meetingStream
                                   select meeting;
        
        log:printInfo("Found " + meetings.length().toString() + " meetings with createdBy field");
        
        // If no meetings found with username, try with user email if available
        if meetings.length() == 0 {
            // Get user email from user record to try email-based search
            var userEmailValue = userRecord["email"];
            if userEmailValue is string {
                map<json> emailFilter = {
                    "createdBy": userEmailValue,
                    "google_calendar_event_id": {"$exists": false}
                };
                
                log:printInfo("Trying email-based filter: " + emailFilter.toString());
                
                stream<Meeting, error?> emailStream = check mongodb:meetingCollection->find(emailFilter);
                meetings = check from Meeting meeting in emailStream
                                select meeting;
                
                log:printInfo("Found " + meetings.length().toString() + " meetings with email in createdBy field");
            }
        }
        
        // Try with the old field names as fallback
        if meetings.length() == 0 {
            map<json> altFilter = {
                "organizer": userPayload.username,
                "google_calendar_event_id": {"$exists": false}
            };
            
            log:printInfo("Trying organizer field fallback: " + altFilter.toString());
            
            stream<Meeting, error?> altStream = check mongodb:meetingCollection->find(altFilter);
            meetings = check from Meeting meeting in altStream
                            select meeting;
            
            log:printInfo("Found " + meetings.length().toString() + " meetings with organizer field");
        }
        
        // Debug: Show all meetings for this user to help troubleshoot
        if meetings.length() == 0 {
            map<json> debugFilter = {"createdBy": userPayload.username};
            stream<Meeting, error?> debugStream = check mongodb:meetingCollection->find(debugFilter);
            Meeting[] allUserMeetings = check from Meeting meeting in debugStream
                                              select meeting;
            log:printInfo("Debug - Total meetings for username: " + allUserMeetings.length().toString());
            
            // Try email debug if available
            var userEmailValue = userRecord["email"];
            if userEmailValue is string {
                map<json> debugEmailFilter = {"createdBy": userEmailValue};
                stream<Meeting, error?> debugEmailStream = check mongodb:meetingCollection->find(debugEmailFilter);
                Meeting[] allEmailMeetings = check from Meeting meeting in debugEmailStream
                                                   select meeting;
                log:printInfo("Debug - Total meetings for email: " + allEmailMeetings.length().toString());
            }
        }
        
        int syncedCount = 0;
        int failedCount = 0;

        foreach Meeting meeting in meetings {
            // Create calendar event data with proper type handling
            json meetingJson = meeting.toJson();
            
            string title = "Meeting";
            string description = "";
            string scheduledTime = "";
            string endTime = "";
            
            // Safely extract fields from JSON
            if meetingJson is map<json> {
                var titleValue = meetingJson["title"];
                if titleValue is string {
                    title = titleValue;
                }
                
                var descValue = meetingJson["description"];
                if descValue is string {
                    description = descValue;
                }
                
                // Handle directTimeSlot structure for direct meetings
                var directTimeSlotValue = meetingJson["directTimeSlot"];
                if directTimeSlotValue is map<json> {
                    var startTimeValue = directTimeSlotValue["startTime"];
                    var endTimeValue = directTimeSlotValue["endTime"];
                    
                    if startTimeValue is string {
                        scheduledTime = startTimeValue;
                    }
                    if endTimeValue is string {
                        endTime = endTimeValue;
                    }
                } else {
                    // Fallback to old field names if directTimeSlot doesn't exist
                    var schedValue = meetingJson["scheduled_time"];
                    if schedValue is string {
                        scheduledTime = schedValue;
                        endTime = scheduledTime; // Default end time to start time
                    }
                    
                    var endValue = meetingJson["end_time"];
                    if endValue is string {
                        endTime = endValue;
                    }
                }
            }
            
            log:printInfo("Creating calendar event for meeting: " + title + " at " + scheduledTime);
            
            json calendarEventData = {
                "summary": title,
                "description": description,
                "start": {
                    "dateTime": scheduledTime,
                    "timeZone": "UTC"
                },
                "end": {
                    "dateTime": endTime,
                    "timeZone": "UTC"
                }
            };

            // Add attendees if available - handle participants array
            if meetingJson is map<json> {
                var participantsValue = meetingJson["participants"];
                if participantsValue is json[] {
                    json[] attendeeList = [];
                    foreach json participantItem in participantsValue {
                        if participantItem is map<json> {
                            var usernameValue = participantItem["username"];
                            if usernameValue is string {
                                // For now, assume username is email or convert to email format
                                string emailAddr = usernameValue.includes("@") ? usernameValue : usernameValue + "@gmail.com";
                                attendeeList.push({"email": emailAddr});
                            }
                        }
                    }
                    if attendeeList.length() > 0 {
                        calendarEventData = check calendarEventData.mergeJson({"attendees": attendeeList});
                    }
                }
                
                // Also check old attendees field format
                var attendeesValue = meetingJson["attendees"];
                if attendeesValue is json[] {
                    json[] attendeeList = [];
                    foreach json attendeeItem in attendeesValue {
                        if attendeeItem is string {
                            attendeeList.push({"email": attendeeItem});
                        }
                    }
                    if attendeeList.length() > 0 {
                        calendarEventData = check calendarEventData.mergeJson({"attendees": attendeeList});
                    }
                }
            }

            // Create Google Calendar event
            string|error eventId = createGoogleCalendarEvent(accessToken, calendarEventData);
            if eventId is string {
                // Update meeting with calendar event ID
                if meetingJson is map<json> {
                    var meetingIdValue = meetingJson["_id"];
                    if meetingIdValue is string {
                        map<string> updateFilter = {"_id": meetingIdValue};
                        mongodb:Update updateDoc = {
                            "set": {
                                "google_calendar_event_id": eventId
                            }
                        };
                        
                        var updateResult = mongodb:meetingCollection->updateOne(updateFilter, updateDoc);
                        if updateResult is error {
                            log:printError("Failed to update meeting with calendar event ID", updateResult);
                            failedCount += 1;
                        } else {
                            syncedCount += 1;
                        }
                    }
                }
            } else {
                string meetingIdStr = "unknown";
                if meetingJson is map<json> {
                    var meetingIdValue = meetingJson["_id"];
                    if meetingIdValue is string {
                        meetingIdStr = meetingIdValue;
                    }
                }
                log:printError("Failed to create calendar event for meeting: " + meetingIdStr, eventId);
                failedCount += 1;
            }
        }

        return {
            success: true,
            message: string `Successfully synced ${syncedCount} meetings to calendar. ${failedCount} failed.`,
            eventId: ""
        };
    }
}

// Helper function to extract JWT token from cookies
function getJWTFromCookies(http:Request request) returns string?|error {
    http:Cookie[] cookies = request.getCookies();
    string? token = ();

    foreach http:Cookie cookie in cookies {
        if cookie.name == "auth_token" {
            token = cookie.value;
            break;
        }
    }

    if token is () {
        string|error authHeader = request.getHeader("Authorization");
        if authHeader is string && authHeader.startsWith("Bearer ") {
            token = authHeader.substring(7);
        }
    }

    return token;
}

// Helper function to validate JWT token
function validateJWT(string token) returns UserPayload|error {
    jwt:ValidatorConfig validatorConfig = {
        issuer: "automeet",
        audience: "automeet-app",
        clockSkew: 60,
        signatureConfig: {
            secret: JWT_SECRET
        }
    };

    jwt:Payload|error validationResult = jwt:validate(token, validatorConfig);
    
    if validationResult is error {
        return error("JWT validation failed: " + validationResult.message());
    }

    jwt:Payload payload = validationResult;

    // Extract user information from JWT payload
    string userId = "";
    string username = "";

    if payload.sub is string {
        username = <string>payload.sub;
    }

    // Try to get user ID from custom claims
    var customClaims = payload["customClaims"];
    if customClaims is map<json> {
        var userIdClaim = customClaims["userId"];
        if userIdClaim is string {
            userId = userIdClaim;
        }
        var usernameClaim = customClaims["username"];
        if usernameClaim is string {
            username = usernameClaim;
        }
    }

    if userId == "" && username != "" {
        // If we only have username, try to get user ID from database
        map<json> userFilter = {"username": username};
        record {}|() userRecord = check mongodb:userCollection->findOne(userFilter);
        if userRecord is () {
            return error("User not found for username: " + username);
        }
        
        // Convert to User type to get ID
        json userJson = userRecord.toJson();
        User user = check userJson.cloneWithType(User);
        userId = user.username; // Since we don't have _id field in our User type, we'll use username as ID
    }

    return {
        id: username,
        username: username,
        iat: payload.iat,
        exp: payload.exp
    };
}

// Helper function to get access token from refresh token
function getAccessTokenFromRefreshToken(string refreshToken) returns string|error {
    http:Client googleTokenClient = check new ("https://oauth2.googleapis.com");
    
    map<string> payload = {
        "client_id": googleClientId,
        "client_secret": googleClientSecret,
        "refresh_token": refreshToken,
        "grant_type": "refresh_token"
    };
    
    http:Response response = check googleTokenClient->post("/token", payload);
    json responseBody = check response.getJsonPayload();
    
    json accessTokenValue = check responseBody.access_token;
    if accessTokenValue is string {
        return accessTokenValue;
    }
    return error("Failed to get access token");
}

// Helper function to create Google Calendar event
function createGoogleCalendarEvent(string accessToken, json eventData) returns string|error {
    http:Client calendarClient = check new ("https://www.googleapis.com");
    
    http:Request request = new;
    request.setHeader("Authorization", "Bearer " + accessToken);
    request.setHeader("Content-Type", "application/json");
    request.setJsonPayload(eventData);
    
    http:Response response = check calendarClient->post("/calendar/v3/calendars/primary/events", request);
    json responseBody = check response.getJsonPayload();
    
    json eventIdValue = check responseBody.id;
    if eventIdValue is string {
        return eventIdValue;
    }
    return error("Failed to create calendar event");
}

// Helper function to update Google Calendar event
function updateGoogleCalendarEvent(string accessToken, string eventId, json eventData) returns string|error {
    http:Client calendarClient = check new ("https://www.googleapis.com");
    
    http:Request request = new;
    request.setHeader("Authorization", "Bearer " + accessToken);
    request.setHeader("Content-Type", "application/json");
    request.setJsonPayload(eventData);
    
    http:Response response = check calendarClient->put("/calendar/v3/calendars/primary/events/" + eventId, request);
    json responseBody = check response.getJsonPayload();
    
    json eventIdValue = check responseBody.id;
    if eventIdValue is string {
        return eventIdValue;
    }
    return error("Failed to update calendar event");
}

// Helper function to delete Google Calendar event
function deleteGoogleCalendarEvent(string accessToken, string eventId) returns error? {
    http:Client calendarClient = check new ("https://www.googleapis.com");
    
    http:Request request = new;
    request.setHeader("Authorization", "Bearer " + accessToken);
    
    http:Response response = check calendarClient->delete("/calendar/v3/calendars/primary/events/" + eventId, request);
    
    if response.statusCode != 204 {
        return error("Failed to delete calendar event. Status: " + response.statusCode.toString());
    }
}
