import mongodb_atlas_app.mongodb;
import ballerina/email;
import ballerina/http;
import ballerina/jwt;
import ballerina/log;
import ballerina/regex;
import ballerina/uuid;
import ballerina/time;

public function checkAndNotifyParticipantsForRoundRobin(Meeting meeting) returns error? {
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
                map<string> participantEmails = check collectParticipantEmails(participantUsernames);

                // Send email notifications
                error? emailResult = sendEmailNotifications(notification, meeting, participantEmails);
                if emailResult is error {
                    log:printError("Failed to send email notifications for availability request", emailResult);
                    // Continue execution even if email sending fails
                }
            }
        }
    }

    return;
}

public function sendAvailabilityRequestNotification(Meeting meeting) returns error? {
    if (meeting.meetingType != "group" && meeting.meetingType != "round_robin") {
        return;
    }

    // Get all participants
    string[] recipients = [];
    foreach MeetingParticipant participant in meeting?.participants ?: [] {
        recipients.push(participant.username);
    }

    if (recipients.length() == 0) {
        return;
    }

    // Create notification for participants
    Notification notification = {
        id: uuid:createType1AsString(),
        title: meeting.title + " - Availability Request",
        message: string `Please submit your availability for the meeting "${meeting.title}".`,
        notificationType: "availability_request",
        meetingId: meeting.id,
        toWhom: recipients,
        createdAt: time:utcToString(time:utcNow())
    };

    // Insert notification
    _ = check mongodb:notificationCollection->insertOne(notification);

    // Handle email notifications
    foreach string recipient in recipients {
        map<json> settingsFilter = {
            "username": recipient
        };
        
        record {}|() settingsRecord = check mongodb:notificationSettingsCollection->findOne(settingsFilter);
        
        // Fix the email notification check
        if (settingsRecord is record {}) {
            json settingsJson = settingsRecord.toJson();
            NotificationSettings settings = check settingsJson.cloneWithType(NotificationSettings);
            
            if settings.email_notifications {
                map<string> recipientEmail = check collectParticipantEmails([recipient]);
                error? emailResult = sendEmailNotifications(notification, meeting, recipientEmail);
                
                if (emailResult is error) {
                    log:printError("Failed to send availability request email", emailResult);
                }
            }
        }
    }
}

// Add to MeetingService.bal or Support.bal
public function checkAndFinalizeTimeSlot(Meeting meeting) returns error? {
    if (meeting.meetingType != "group" && meeting.meetingType != "round_robin") {
        return;
    }
    
    // Get all availability entries for this meeting
    map<json> availFilter = {
        "meetingId": meeting.id
    };
    
    stream<record {}, error?> availCursor = check mongodb:availabilityCollection->find(availFilter);
    TimeSlot? latestTimeSlot = ();
    
    // Process availabilities to find the latest time slot
    check from record {} availData in availCursor
        do {
            json availJson = availData.toJson();
            Availability availability = check availJson.cloneWithType(Availability);
            
            foreach TimeSlot slot in availability.timeSlots {
                if (latestTimeSlot is () || slot.endTime > latestTimeSlot.endTime) {
                    latestTimeSlot = slot;
                }
            }
        };
    
    if (latestTimeSlot is ()) {
        return;
    }

    // Get notification recipients (creator and hosts only)
    string[] recipients = [meeting.createdBy];
    
    // Add hosts for round robin meetings
    if (meeting.meetingType == "round_robin" && meeting?.hosts is MeetingParticipant[]) {
        foreach MeetingParticipant host in meeting?.hosts ?: [] {
            if (host.username != meeting.createdBy) {  // Avoid duplicates
                recipients.push(host.username);
            }
        }
    }

    // Create and send notification
    Notification notification = {
        id: uuid:createType1AsString(),
        title: meeting.title + " - Availability Update",
        message: string `New participant availability submission received for "${meeting.title}". ` + 
                string `Latest submission deadline is ${latestTimeSlot.endTime}.`,
        notificationType: "availability_update",
        meetingId: meeting.id,
        toWhom: recipients,
        createdAt: time:utcToString(time:utcNow())
    };

    // Check notification status
    map<json> notificationFilter = {
        "meetingId": meeting.id
    };
    
    record {}|() notificationStatus = check mongodb:availabilityNotificationStatusCollection->findOne(notificationFilter);
    string currentDate = time:utcToString(time:utcNow()).substring(0, 10);
    
    if (notificationStatus is record {}) {
        json statusJson = notificationStatus.toJson();
        AvailabilityNotificationStatus status = check statusJson.cloneWithType(AvailabilityNotificationStatus);
        
        if (status.lastNotificationDate == currentDate) {
            mongodb:Update updateOperation = {
                "set": {
                    "submissionCount": status.submissionCount + 1
                }
            };
            _ = check mongodb:availabilityNotificationStatusCollection->updateOne(notificationFilter, updateOperation);
            return;
        }
    }

    // Update notification status
    AvailabilityNotificationStatus newStatus = {
        meetingId: meeting.id,
        lastNotificationDate: currentDate,
        submissionCount: 1
    };

    mongodb:Update statusUpdate = {
        "set": <map<json>> newStatus.toJson()
    };
    
    _ = check mongodb:availabilityNotificationStatusCollection->updateOne(
        notificationFilter,
        statusUpdate,
        {"upsert": true}
    );

    // Insert notification if first submission of the day
    if (notificationStatus is () || (<record {}>notificationStatus).toJson().lastNotificationDate != currentDate) {
        _ = check mongodb:notificationCollection->insertOne(notification);
        
        // Handle email notifications for recipients
        foreach string recipient in recipients {
            map<json> settingsFilter = {
                "username": recipient
            };
            
            record {}|() settingsRecord = check mongodb:notificationSettingsCollection->findOne(settingsFilter);
            
            if (settingsRecord is record {}) {
                NotificationSettings|error settings = settingsRecord.toJson().cloneWithType(NotificationSettings);
                if settings is NotificationSettings && settings.email_notifications {
                map<string> recipientEmail = check collectParticipantEmails([recipient]);
                error? emailResult = sendEmailNotifications(notification, meeting, recipientEmail);
                
                if (emailResult is error) {
                    log:printError("Failed to send availability update email", emailResult);
                }
            }
        }
    }


    return;
}
}

public function findBestTimeSlot(Meeting meeting) returns TimeSlot?|error {
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
            map<string> decisionMakerEmails = check collectParticipantEmails(emailRecipients);

            // Send email notifications
            error? emailResult = sendEmailNotifications(notification, meeting, decisionMakerEmails);

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

// Helper function to notify the creator to reschedule
public function notifyCreatorToReschedule(Meeting meeting) returns error? {
    // Create notification for the creator
    string[] recipients = [meeting.createdBy];

    Notification notification = {
        id: uuid:createType1AsString(),
        title: meeting.title + " - Deadline Passed",
        message: "The deadline for meeting " + meeting.title +
                " has passed without sufficient availability data. Please reschedule the meeting.",
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
            map<string> creatorEmail = check collectParticipantEmails([meeting.createdBy]);
            error? emailResult = sendEmailNotifications(notification, meeting, creatorEmail);

            if (emailResult is error) {
                log:printError("Failed to send reschedule email notification to creator");
                // Continue execution even if email sending fails
            }
        }
    }

    return;
}

// New helper function to extract JWT token from cookie
public function validateAndGetUsernameFromCookie(http:Request request) returns string?|error {
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
            secret: JWT_SECRET // For HMAC based JWT
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

public function processHosts(string creatorUsername, string[] hostIds) returns MeetingParticipant[]|error {
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
            access: "accepted" // Hosts always have accepted access
        });
    }

    // Ensure at least one host is processed
    if processedHosts.length() == 0 {
        return error("No valid hosts could be processed");
    }

    return processedHosts;
}

public function processParticipants(string creatorUsername, string[] participantIds) returns MeetingParticipant[]|error {
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
            username: contactUsername, // Use the contact's username instead of ID
            access: "pending"
        });
    }

    // Ensure at least one participant is processed
    if processedParticipants.length() == 0 {
        return error("No valid participants could be processed");
    }

    return processedParticipants;
}

public function sendEmailNotifications(Notification notification, Meeting meeting, map<string> participantEmails) returns error? {
    EmailConfig emailConfig = {
        host: "smtp.gmail.com",
        username: "automeetitfac@gmail.com",
        password: "psec mnvm mevn rfuj",
        frontendUrl: "http://localhost:3000"
    };
    
    email:SmtpClient|error smtpClient = new (emailConfig.host, emailConfig.username, emailConfig.password);

    if smtpClient is error {
        log:printError("Failed to create SMTP client", smtpClient);
        return smtpClient;
    }
    
    foreach string username in notification.toWhom {
        if !participantEmails.hasKey(username) {
            log:printWarn("No email address found for user: " + username);
            continue;
        }

        string recipientEmail = participantEmails[username] ?: "";
        
        // Check if user exists in user collection
        map<json> userFilter = {
            "username": username
        };
        
        record {}|() userRecord = check mongodb:userCollection->findOne(userFilter);
        string meetingLink;
        
        if userRecord is () {
            // User not in system - generate external links based on notification type
            if notification.notificationType == "availability_request" {
                // Generate a UUID for external user
                string externalUserId = uuid:createType1AsString();
                meetingLink = string `${emailConfig.frontendUrl}/exavailability/${externalUserId}/${meeting.id}`;
            } else if notification.notificationType == "confirmation" || 
                      notification.notificationType == "cancellation" {
                meetingLink = string `${emailConfig.frontendUrl}/exmeetingdetails/${meeting.id}`;
            } else {
                meetingLink = string `${emailConfig.frontendUrl}/exmeetingdetails/${meeting.id}`;
            }
        } else {
            // Regular user - use normal meeting link
            meetingLink = string `${emailConfig.frontendUrl}/meetingdetails/${meeting.id}`;
        }
        
        // Get email template and customize it
        EmailTemplate template = getEmailTemplate(notification.notificationType, meeting.title);
        
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
        
        // Add meeting details
        personalizedBody = personalizedBody + "\n\nMeeting Details:\n" +
            "Location: " + meeting.location + "\n" +
            "Description: " + meeting.description;
        
        // Add time information based on meeting type
        if meeting.meetingType == "direct" && meeting?.directTimeSlot is TimeSlot {
            TimeSlot timeSlot = <TimeSlot>meeting?.directTimeSlot;
            personalizedBody = personalizedBody + "\nTime: " + timeSlot.startTime + " to " + timeSlot.endTime;
        } else if meeting.meetingType == "group" || meeting.meetingType == "round_robin" {
            if userRecord is () {
                personalizedBody = personalizedBody + "\nPlease use the link above to submit your availability. " +
                                 "No registration required.";
            } else {
                personalizedBody = personalizedBody + "\nPlease mark your availability using the link above.";
            }
        }

        // Create email message
        email:Message emailMsg = {
            to: recipientEmail,
            subject: template.subject,
            body: personalizedBody,
            htmlBody: getHtmlEmail(meeting.title, personalizedBody, meetingLink)
        };

        // Send email
        error? sendResult = smtpClient->sendMessage(emailMsg);

        if sendResult is error {
            log:printError("Failed to send email to " + recipientEmail, sendResult);
        } else {
            log:printInfo("Email sent successfully to " + recipientEmail);
        }
    }

    return;
}

public function getEmailTemplate(NotificationType notificationType, string meetingTitle) returns EmailTemplate {
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

public function getHtmlEmail(string meetingTitle, string textContent, string meetingLink) returns string {
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

public function collectParticipantEmails(string[] usernames) returns map<string>|error {
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

public function createMeetingNotification(string meetingId, string meetingTitle, MeetingType meetingType, MeetingParticipant[] participants, MeetingParticipant[]? hosts = ()) returns Notification|error {
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
                map<string> creatorEmails = check collectParticipantEmails(creatorAndHostRecipients);

                // Send email notifications
                error? emailResult = sendEmailNotifications(creatorHostNotification, meeting, creatorEmails);

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
                map<string> participantEmails = check collectParticipantEmails(participantRecipients);

                // Send email notifications
                error? emailResult = sendEmailNotifications(participantNotification, meeting, participantEmails);

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

// Function to validate that all contact IDs belong to the user
public function validateContactIds(string username, string[] contactIds) returns boolean|error {
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

// Utility method to verify calendar access with the given access token
public function verifyCalendarAccess(string accessToken) returns boolean|error {
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

// Helper method to generate JWT token with fixed customClaims
public function generateJwtToken(User user) returns string|error {
    // Create a proper map for custom claims
    map<json> _ = {
        "name": user.name,
        "role": user.role
    };

    // Create a proper map for custom claims
    jwt:IssuerConfig issuerConfig = {
        username: user.username, // This sets the 'sub' field
        issuer: "automeet",
        audience: ["automeet-app"],
        expTime: <decimal>time:utcNow()[0] + 36000, // Token valid for 1 hour
        signatureConfig: {
            algorithm: jwt:HS256,
            config: JWT_SECRET
        },
        customClaims: {
            "username": user.username, // Add this explicitly for custom access
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

public function hasAuthorizationHeader(http:Request req) returns boolean {
    return req.hasHeader("Authorization");
}


// Enhanced participant processing function that handles both registered and unregistered users
public function processParticipantsWithEmails(string creatorUsername, string[] participantIds, string meetingId, MeetingType meetingType) returns MeetingParticipant[]|error {
    if participantIds.length() == 0 {
        return [];
    }
    
    MeetingParticipant[] processedParticipants = [];
    string[] unregisteredParticipants = [];
    map<string> participantEmails = {};
    
    // Process each participant
    foreach string participantId in participantIds {
        // Create a filter to find the contact
        map<json> contactFilter = {
            "id": participantId,
            "createdBy": creatorUsername
        };
        
        // Query the contacts collection
        record {}|() contact = check mongodb:contactCollection->findOne(contactFilter);
        
        if contact is () {
            return error("Invalid participant ID: Participant must be in the user's contacts");
        }
        
        // Extract contact details
        json contactJson = contact.toJson();
        string contactUsername = check contactJson.username.ensureType();
        string contactEmail = check contactJson.email.ensureType();
        
        // Store email for later use
        participantEmails[contactUsername] = contactEmail;
        
        // Check if this contact is a registered user
        map<json> userFilter = {
            "username": contactUsername
        };
        
        record {}|() userRecord = check mongodb:userCollection->findOne(userFilter);
        
        if userRecord is () {
            // Unregistered user - add to unregistered list
            unregisteredParticipants.push(contactUsername);
        }
        
        // Add to processed participants regardless of registration status
        processedParticipants.push({
            username: contactUsername,
            access: "pending",
            email: contactEmail
        });
    }
    
    // Send appropriate emails to unregistered participants
    if unregisteredParticipants.length() > 0 {
        error? emailResult = sendUnregisteredParticipantEmails(
            unregisteredParticipants, 
            participantEmails, 
            meetingId, 
            meetingType
        );
        
        if emailResult is error {
            log:printError("Failed to send emails to unregistered participants", emailResult);
            // Continue execution even if email sending fails
        }
    }
    
    return processedParticipants;
}

// Function to send emails to unregistered participants with appropriate links
public function sendUnregisteredParticipantEmails(string[] unregisteredUsernames, map<string> participantEmails, string meetingId, MeetingType meetingType) returns error? {
    
    EmailConfig emailConfig = {
        host: "smtp.gmail.com",
        username: "automeetitfac@gmail.com",
        password: "psec mnvm mevn rfuj",
        frontendUrl: "http://localhost:3000"
    };
    
    email:SmtpClient|error smtpClient = new (emailConfig.host, emailConfig.username, emailConfig.password);
    
    if smtpClient is error {
        log:printError("Failed to create SMTP client", smtpClient);
        return smtpClient;
    }
    
    // Get meeting details for email content
    map<json> meetingFilter = {
        "id": meetingId
    };
    
    record {}|() meetingRecord = check mongodb:meetingCollection->findOne(meetingFilter);
    if meetingRecord is () {
        return error("Meeting not found");
    }
    
    json meetingJson = meetingRecord.toJson();
    Meeting meeting = check meetingJson.cloneWithType(Meeting);
    
    foreach string username in unregisteredUsernames {
        if !participantEmails.hasKey(username) {
            log:printWarn("No email address found for unregistered user: " + username);
            continue;
        }
        
        string recipientEmail = participantEmails[username] ?: "";
        
        // Generate UUID for external user
        string externalUserId = uuid:createType1AsString();
        
        // Store the external user mapping for future reference
        ExternalUserMapping userMapping = {
            id: uuid:createType1AsString(),
            externalUserId: externalUserId,
            email: recipientEmail,
            meetingId: meetingId,
            createdAt: time:utcToString(time:utcNow())
        };
        
        _ = check mongodb:externalUserMappingCollection->insertOne(userMapping);
        
        // Generate appropriate link based on meeting type
        string meetingLink;
        string emailSubject;
        string emailBody;
        
        if meetingType == "direct" {
            meetingLink = string `${emailConfig.frontendUrl}/exmeetingdetails/${meetingId}`;
            emailSubject = "[AutoMeet] You've been invited to a meeting: " + meeting.title;
            emailBody = string `You have been invited to a meeting: "${meeting.title}"
            
Meeting Details:
- Location: ${meeting.location}
- Description: ${meeting.description}
- Type: Direct Meeting`;
            
            // Add time information if available
            if meeting?.directTimeSlot is TimeSlot {
                TimeSlot timeSlot = <TimeSlot>meeting?.directTimeSlot;
                emailBody = emailBody + string `
- Time: ${timeSlot.startTime} to ${timeSlot.endTime}`;
            }
            
            emailBody = emailBody + string `

Click the link below to view the meeting details:
${meetingLink}

No registration required. You can view the meeting information directly.`;
            
        } else { // group or round_robin
            meetingLink = string `${emailConfig.frontendUrl}/exavailability/${externalUserId}/${meetingId}`;
            emailSubject = "[AutoMeet] Please mark your availability: " + meeting.title;
            emailBody = string `You have been invited to a meeting: "${meeting.title}"
            
Meeting Details:
- Location: ${meeting.location}
- Description: ${meeting.description}
- Type: ${meetingType == "group" ? "Group Meeting" : "Round Robin Meeting"}`;
            
            // Add duration information if available
            if meetingType == "group" && meeting?.groupDuration is string {
                emailBody = emailBody + string `
- Duration: ${meeting?.groupDuration ?: ""}`;
            } else if meetingType == "round_robin" && meeting?.roundRobinDuration is string {
                emailBody = emailBody + string `
- Duration: ${meeting?.roundRobinDuration ?: ""}`;
            }
            
            emailBody = emailBody + string `

Please click the link below to mark your availability:
${meetingLink}

No registration required. Simply select your available time slots to help us find the best meeting time for everyone.`;
        }
        
        // Create and send email
        email:Message emailMsg = {
            to: recipientEmail,
            subject: emailSubject,
            body: emailBody,
            htmlBody: getUnregisteredUserHtmlEmail(meeting.title, emailBody, meetingLink, meetingType)
        };
        
        error? sendResult = smtpClient->sendMessage(emailMsg);
        
        if sendResult is error {
            log:printError("Failed to send email to unregistered user " + recipientEmail, sendResult);
        } else {
            log:printInfo("Email sent successfully to unregistered user " + recipientEmail);
        }
    }
    
    return;
}

// HTML email template for unregistered users
public function getUnregisteredUserHtmlEmail(string meetingTitle, string textContent, string meetingLink, MeetingType meetingType) returns string {
    string actionText = meetingType == "direct" ? "View Meeting Details" : "Mark Your Availability";
    string instructionText = meetingType == "direct" ? 
        "Click below to view the meeting details" : 
        "Click below to select your available time slots";
    
    return string `
    <html>
        <head>
            <style>
                body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; margin: 0; padding: 0; }
                .container { max-width: 600px; margin: 0 auto; padding: 20px; background-color: #f9f9f9; }
                .header { background-color: #4a86e8; color: white; padding: 20px; border-radius: 8px 8px 0 0; text-align: center; }
                .content { padding: 30px; border: 1px solid #ddd; border-top: none; border-radius: 0 0 8px 8px; background-color: white; }
                .button { display: inline-block; background-color: #4a86e8; color: white; padding: 12px 24px; 
                        text-decoration: none; border-radius: 6px; margin-top: 20px; font-weight: bold; }
                .button:hover { background-color: #3a76d8; }
                .meeting-info { background-color: #f8f9fa; padding: 15px; border-radius: 5px; margin: 15px 0; }
                .footer { margin-top: 20px; font-size: 12px; color: #777; text-align: center; 
                         border-top: 1px solid #eee; padding-top: 15px; }
                .highlight { color: #4a86e8; font-weight: bold; }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="header">
                    <h2>🤝 AutoMeet Invitation</h2>
                </div>
                <div class="content">
                    <h3>You're invited to: <span class="highlight">${meetingTitle}</span></h3>
                    <div class="meeting-info">
                        ${regex:replaceAll(textContent, "\n", "<br/>")}
                    </div>
                    <p><strong>${instructionText}:</strong></p>
                    <div style="text-align: center;">
                        <a href="${meetingLink}" class="button">${actionText}</a>
                    </div>
                    <p style="margin-top: 20px; font-size: 14px; color: #666;">
                        <strong>Note:</strong> No account registration is required. This link is specifically created for you to participate in this meeting.
                    </p>
                </div>
                <div class="footer">
                    <p>This is an automated invitation from AutoMeet. Please do not reply to this email.</p>
                    <p>If you have any questions about this meeting, please contact the meeting organizer directly.</p>
                </div>
            </div>
        </body>
    </html>
    `;
}



// Updated createMeetingNotification function to handle mixed participant types
public function createMeetingNotificationWithMixedParticipants(
    string meetingId, 
    string meetingTitle, 
    MeetingType meetingType, 
    MeetingParticipant[] participants, 
    MeetingParticipant[]? hosts = ()
) returns Notification|error {
    
    // Separate registered and unregistered participants
    string[] registeredParticipants = [];
    string[] unregisteredParticipants = [];
    
    foreach MeetingParticipant participant in participants {
        // Check if participant is registered
        map<json> userFilter = {
            "username": participant.username
        };
        
        record {}|() userRecord = check mongodb:userCollection->findOne(userFilter);
        
        if userRecord is record {} {
            registeredParticipants.push(participant.username);
        } else {
            unregisteredParticipants.push(participant.username);
        }
    }
    
    // Create notifications only for registered participants
    if registeredParticipants.length() > 0 {
        string participantTitle;
        string participantMessage;
        NotificationType participantNotifType;
        
        if meetingType == "direct" {
            participantTitle = meetingTitle + " - Meeting Invitation";
            participantMessage = "You have been invited to a new meeting: " + meetingTitle;
            participantNotifType = "creation";
        } else {
            participantTitle = meetingTitle + " - Please Mark Your Availability";
            participantMessage = "You have been invited to a new " + 
                (meetingType == "group" ? "group" : "round-robin") + 
                " meeting: \"" + meetingTitle + "\". Please mark your availability.";
            participantNotifType = "availability_request";
        }
        
        Notification participantNotification = {
            id: uuid:createType1AsString(),
            title: participantTitle,
            message: participantMessage,
            notificationType: participantNotifType,
            meetingId: meetingId,
            toWhom: registeredParticipants,
            createdAt: time:utcToString(time:utcNow())
        };
        
        // Insert the notification
        _ = check mongodb:notificationCollection->insertOne(participantNotification);
        
        // Send email notifications to registered participants
        if registeredParticipants.length() > 0 {
            map<json> meetingFilter = {
                "id": meetingId
            };
            
            record {}|() meetingRecord = check mongodb:meetingCollection->findOne(meetingFilter);
            
            if meetingRecord is record {} {
                json meetingJson = meetingRecord.toJson();
                Meeting meeting = check meetingJson.cloneWithType(Meeting);
                
                // Collect email addresses for registered participants
                map<string> participantEmails = check collectParticipantEmails(registeredParticipants);
                
                // Send email notifications
                error? emailResult = sendEmailNotifications(participantNotification, meeting, participantEmails);
                
                if emailResult is error {
                    log:printError("Failed to send email notifications to registered participants", emailResult);
                }
            }
        }
    }
    
    // Log information about unregistered participants (emails already sent in processParticipantsWithEmails)
    if unregisteredParticipants.length() > 0 {
        log:printInfo(string `Sent external invitation emails to ${unregisteredParticipants.length()} unregistered participants for meeting: ${meetingTitle}`);
    }
    
    // Return a notification representing the overall process
    return {
        id: uuid:createType1AsString(),
        title: meetingTitle,
        message: string `Meeting notifications sent to ${registeredParticipants.length()} registered and ${unregisteredParticipants.length()} unregistered participants`,
        notificationType: "creation",
        meetingId: meetingId,
        toWhom: registeredParticipants,
        createdAt: time:utcToString(time:utcNow())
    };
}

public function sendWelcomeEmail(string userEmail, string userName) returns error? {
    // Email configuration
    EmailConfig emailConfig = {
        host: "smtp.gmail.com",
        username: "somapalagalagedara@gmail.com",
        password: "wzhd plxq isxl nddc",
        frontendUrl: "http://localhost:5173"
    };

    // Create SMTP configuration for better security
    email:SmtpConfiguration smtpConfig = {
        port: 587,
        security: email:START_TLS_AUTO
    };

    email:SmtpClient|error smtpClient = new (emailConfig.host, emailConfig.username, emailConfig.password, smtpConfig);

    if smtpClient is error {
        log:printError("Failed to create SMTP client for welcome email", smtpClient);
        return smtpClient;
    }

    string htmlContent = getWelcomeEmailHtml(userName, emailConfig.frontendUrl);

    email:Message welcomeEmail = {
        to: userEmail,
        subject: "Welcome to AUTOMEET! 🎉",
        body: string `Dear ${userName},

Welcome to AUTOMEET! 🚀

Thank you for joining our platform - THE easiest way to schedule anything collaboratively.

Best regards,
The AUTOMEET Team`,
        htmlBody: htmlContent
    };

    error? sendResult = smtpClient->sendMessage(welcomeEmail);
    
    if sendResult is error {
        log:printError("Failed to send welcome email to " + userEmail, sendResult);
        return sendResult;
    }
    
    log:printInfo("Welcome email sent successfully to: " + userEmail);
    return;
}

// Send registration welcome email asynchronously (non-blocking)
public function sendWelcomeEmailAsync(string userEmail, string userName) {
    worker welcomeEmailWorker {
        error? result = sendWelcomeEmail(userEmail, userName);
        if result is error {
            log:printError("Async welcome email sending failed", result);
        }
    }
}

// HTML template for login welcome email
function getLoginWelcomeEmailHtml(string userName, string loginTime, string loginDevice, string frontendUrl) returns string {
    return string `
    <!DOCTYPE html>
    <html>
        <head>
            <style>
                body { font-family: 'Segoe UI', Arial, sans-serif; line-height: 1.6; color: #333; margin: 0; padding: 0; background-color: #f5f8fa; }
                .container { max-width: 600px; margin: 20px auto; background: white; border-radius: 12px; overflow: hidden; box-shadow: 0 4px 20px rgba(0,0,0,0.1); }
                .header { background: linear-gradient(135deg, #28a745, #1e7e34); color: white; padding: 30px 20px; text-align: center; }
                .header h1 { margin: 0; font-size: 28px; font-weight: 600; }
                .welcome-icon { font-size: 48px; margin-bottom: 15px; }
                .content { padding: 30px; }
                .login-info { background: #e8f5e8; padding: 20px; border-radius: 8px; margin: 20px 0; border-left: 4px solid #28a745; }
                .quick-actions { display: flex; flex-direction: column; gap: 10px; margin: 25px 0; }
                .action-button { display: inline-block; background: linear-gradient(135deg, #007bff, #0056b3); color: white; padding: 12px 20px; text-decoration: none; border-radius: 6px; text-align: center; font-weight: 500; margin: 5px 0; }
                .dashboard-button { background: linear-gradient(135deg, #28a745, #1e7e34); }
                .footer { text-align: center; color: #666; font-size: 12px; margin-top: 20px; padding: 20px; background: #f8f9fa; }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="header">
                    <div class="welcome-icon">👋</div>
                    <h1>Welcome Back!</h1>
                </div>
                <div class="content">
                    <h2>Hello ${userName}!</h2>
                    <p>Great to see you back on AUTOMEET! You're all set to manage your meetings efficiently.</p>
                    
                    <div class="login-info">
                        <h4>🔐 Login Details</h4>
                        <p><strong>Login Time:</strong> ${loginTime}<br>
                        <strong>Device:</strong> ${loginDevice}</p>
                    </div>
                    
                    <h3>Quick Actions:</h3>
                    <div class="quick-actions">
                        <a href="${frontendUrl}/#/" class="action-button dashboard-button">Go to Dashboard</a>
                        <a href="${frontendUrl}/#/direct" class="action-button">Schedule Direct Meeting</a>
                        <a href="${frontendUrl}/#/group" class="action-button">Create Group Meeting</a>
                        <a href="${frontendUrl}/#/roundrobin" class="action-button">Setup Round Robin</a>
                    </div>
                    
                    <p>💡 <strong>Tip:</strong> Use our Chrome extension for quick access to all your scheduling needs!</p>
                    
                    <p>Need help? Check out our quick guides or contact support.</p>
                    
                    <p>Happy scheduling!<br><strong>The AUTOMEET Team</strong></p>
                </div>
                <div class="footer">
                    <p>This is an automated message from AUTOMEET. Please do not reply to this email.</p>
                    <p>If you didn't log in, please contact our support team immediately.</p>
                </div>
            </div>
        </body>
    </html>
    `;
}

// HTML template for registration welcome email
function getWelcomeEmailHtml(string userName, string frontendUrl) returns string {
    return string `
    <!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome to AutoMeet</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap');
        
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            line-height: 1.6;
            color: #333;
            background-color: #f5f7fa;
            margin: 0;
            padding: 20px 0;
        }
        
        .email-container {
            max-width: 600px;
            margin: 0 auto;
            background: #ffffff;
            border-radius: 16px;
            overflow: hidden;
            box-shadow: 0 4px 20px rgba(0, 0, 0, 0.08);
        }
        
        .header {
            background: linear-gradient(135deg, #6366f1 0%, #8b5cf6 100%);
            padding: 40px 30px;
            text-align: center;
            color: white;
            position: relative;
        }

        .header-image {
            width: 100%;
            max-width: 500px;
            height: 200px;
            object-fit: cover;
            border-radius: 12px;
            margin-bottom: 30px;
            box-shadow: 0 8px 25px rgba(0, 0, 0, 0.2);
        }
        
        .logo {
            font-size: 24px;
            font-weight: 700;
            color: white;
            margin-bottom: 30px;
            letter-spacing: -0.02em;
        }
        
        .hero-title {
            font-size: 32px;
            font-weight: 700;
            margin-bottom: 16px;
            line-height: 1.2;
            letter-spacing: -0.02em;
        }
        
        .hero-subtitle {
            font-size: 18px;
            font-weight: 400;
            opacity: 0.9;
            line-height: 1.4;
        }
        
        .content {
            padding: 40px 30px;
        }
        
        .greeting {
            font-size: 24px;
            font-weight: 600;
            color: #1a1a1a;
            margin-bottom: 20px;
        }
        
        .intro-text {
            font-size: 16px;
            color: #6b7280;
            margin-bottom: 40px;
            line-height: 1.6;
        }
        
        .section-title {
            font-size: 28px;
            font-weight: 700;
            color: #1a1a1a;
            text-align: center;
            margin-bottom: 40px;
            line-height: 1.3;
        }
        
        .features-container {
            margin-bottom: 40px;
        }
        
        .feature-row {
            display: flex;
            align-items: center;
            margin-bottom: 30px;
            padding: 20px;
            background: #f8fafc;
            border-radius: 12px;
            border: 1px solid #e2e8f0;
        }
        
        .feature-icon {
            width: 60px;
            height: 60px;
            border-radius: 12px;
            background: linear-gradient(135deg, #6366f1, #8b5cf6);
            display: flex;
            align-items: center;
            justify-content: center;
            margin-right: 20px;
            flex-shrink: 0;
        }
        
        .feature-icon::before {
            content: '';
            width: 24px;
            height: 24px;
            background: white;
            border-radius: 4px;
        }
        
        .feature-content {
            flex: 1;
        }
        
        .feature-title {
            font-size: 18px;
            font-weight: 600;
            color: #1a1a1a;
            margin-bottom: 6px;
        }
        
        .feature-desc {
            font-size: 14px;
            color: #6b7280;
            line-height: 1.5;
        }
        
        .highlight-section {
            background: linear-gradient(135deg, #f8fafc 0%, #e2e8f0 100%);
            padding: 30px;
            border-radius: 12px;
            text-align: center;
            margin: 40px 0;
        }
        
        .highlight-title {
            font-size: 22px;
            font-weight: 600;
            color: #1a1a1a;
            margin-bottom: 12px;
        }
        
        .highlight-text {
            font-size: 16px;
            color: #6b7280;
            margin-bottom: 25px;
            line-height: 1.5;
        }
        
        .cta-button {
            display: inline-block;
            background-color: #6366f1;
            color: white;
            padding: 16px 32px;
            text-decoration: none;
            border-radius: 10px;
            font-weight: 600;
            font-size: 16px;
            box-shadow: 0 4px 15px rgba(99, 102, 241, 0.3);
        }
        
        
        
        .key-features {
            margin: 40px 0;
        }
        
        .key-features-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
            margin-top: 20px;
        }
        
        .key-feature {
            text-align: center;
            padding: 20px;
            background: #ffffff;
            border: 1px solid #e2e8f0;
            border-radius: 10px;
        }
        
        .key-feature-icon {
            width: 80px;
            height: 60px;
            border-radius: 8px;
            margin: 0 auto 12px;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .key-feature-icon img {
            max-width: 100%;
            height: auto;
        }
        
        .key-feature-icon::before {
            content: '';
            width: 16px;
            height: 16px;
            border-radius: 2px;
        }
        
        .key-feature-title {
            font-size: 14px;
            font-weight: 600;
            color: #1a1a1a;
            margin-bottom: 8px;
        }
        
        .key-feature-desc {
            font-size: 12px;
            color: #6b7280;
            line-height: 1.4;
        }
        
        .footer-section {
            background: #f8fafc;
            padding: 30px;
            text-align: center;
            margin-top: 40px;
        }
        
        .footer-text {
            font-size: 16px;
            color: #6b7280;
            margin-bottom: 20px;
        }
        
        .signature {
            font-size: 16px;
            color: #1a1a1a;
            font-weight: 500;
        }
        
        .footer {
            background: #2d3748;
            color: #a0aec0;
            padding: 20px 30px;
            text-align: center;
        }
        
        .footer-logo {
            font-size: 20px;
            font-weight: 700;
            color: white;
            margin-bottom: 10px;
        }
        
        .footer-disclaimer {
            font-size: 12px;
            line-height: 1.4;
        }
        
        /* Mobile Responsive */
        @media (max-width: 640px) {
            body {
                padding: 10px;
            }
            
            .email-container {
                margin: 0;
                border-radius: 12px;
            }
            
            .header {
                padding: 30px 20px;
            }
            
            .hero-title {
                font-size: 24px;
            }
            
            .hero-subtitle {
                font-size: 16px;
            }
            
            .content {
                padding: 30px 20px;
            }
            
            .greeting {
                font-size: 20px;
            }
            
            .section-title {
                font-size: 22px;
            }
            
            .feature-row {
                flex-direction: column;
                text-align: center;
                padding: 20px 15px;
            }
            
            .feature-icon {
                margin-right: 0;
                margin-bottom: 15px;
            }
            
            .highlight-section {
                padding: 20px;
            }
            
            .highlight-title {
                font-size: 18px;
            }
            
            .key-features-grid {
                grid-template-columns: 1fr;
                gap: 15px;
            }
            
            .footer {
                padding: 20px;
            }
        }
        
        @media (max-width: 480px) {
            .hero-title {
                font-size: 20px;
            }
            
            .section-title {
                font-size: 20px;
            }
            
            .cta-button {
                padding: 14px 24px;
                font-size: 14px;
            }
        }
    </style>
</head>
<body>
    <div class="email-container">
        <div class="header">
            <div class="logo">AutoMeet</div>
             <img src="https://res.cloudinary.com/duocpqb1j/image/upload/v1752751990/xpmvw3typrkpnuybc9bl.jpg" alt="AutoMeet Team Collaboration" class="header-image">
            <h1 class="hero-title">Meetings That Run Themselves</h1>
            <p class="hero-subtitle">Welcome to effortless meeting management</p>
        </div>
        
        <div class="content">
            <h2 class="greeting">Hello ${userName}!</h2>
            <p class="intro-text">
                Tired of managing calendars, links, and notes? AutoMeet automates organizing, hosting, and 
                summarizing your meetings effortlessly. <strong>Welcome to the future of meeting management.</strong>
            </p>
            
            <h3 class="section-title">Seize the Day,<br>One Meeting at a Time!</h3>
            
            <div class="features-container">
                <div class="feature-row">
                    <div class="feature-icon"></div>
                    <div class="feature-content">
                        <div class="feature-title">Direct Meetings</div>
                        <div class="feature-desc">Schedule one-on-one meetings with smart availability detection and automatic coordination</div>
                    </div>
                </div>
                
                <div class="feature-row">
                    <div class="feature-icon"></div>
                    <div class="feature-content">
                        <div class="feature-title">Group Meetings</div>
                        <div class="feature-desc">Coordinate meetings with multiple participants using AI-powered scheduling optimization</div>
                    </div>
                </div>
                
                <div class="feature-row">
                    <div class="feature-icon"></div>
                    <div class="feature-content">
                        <div class="feature-title">Round Robin Meetings</div>
                        <div class="feature-desc">Set up rotating meeting schedules with automatic participant management</div>
                    </div>
                </div>
            </div>
            
            <div class="highlight-section">
                <h3 class="highlight-title">One Platform to Schedule, Analyze, and Run Meetings Better</h3>
                <p class="highlight-text">
                    AutoMeet simplifies meeting scheduling with AI, real-time availability, seamless collaboration, 
                    smart notifications, and analysis for participants.
                </p>
                <a href="${frontendUrl}/#/login" class="cta-button">Get Started</a>
            </div>
            
            <div class="key-features">
                <h3 class="section-title">Features That Do the Work for You</h3>
                <div class="key-features-grid">
                    <div class="key-feature">
                        <div class="key-feature-icon"><img src="https://res.cloudinary.com/duocpqb1j/image/upload/v1752746919/ebzs2ou3kojckzflq5y7.png" alt=""></div>
                        <div class="key-feature-title">Instant Meeting Links</div>
                        <div class="key-feature-desc">Generate and share meeting links with a single click</div>
                    </div>
                    
                    <div class="key-feature">
                        <div class="key-feature-icon"><img src="https://res.cloudinary.com/duocpqb1j/image/upload/v1752746919/vlmf3yxi95u1ym77yqf6.png" alt=""></div>
                        <div class="key-feature-title">Smart Integrations</div>
                        <div class="key-feature-desc">Connect email, calendars, and messaging apps effortlessly</div>
                    </div>
                    
                    <div class="key-feature">
                        <div class="key-feature-icon"><img src="https://res.cloudinary.com/duocpqb1j/image/upload/v1752746919/misp46bbiusevcnhtctl.png" alt=""></div>
                        <div class="key-feature-title">Seamless Scheduling</div>
                        <div class="key-feature-desc">AutoMeet syncs calendars to find the perfect time, no hassle</div>
                    </div>
                    
                    <div class="key-feature">
                        <div class="key-feature-icon"><img src="https://res.cloudinary.com/duocpqb1j/image/upload/v1752746919/bsruvztvo215e3c0fpuk.png" alt=""></div>
                        <div class="key-feature-title">AI-Powered Summaries</div>
                        <div class="key-feature-desc">Get AutoMeet to handle the details so you focus on conversation</div>
                    </div>
                </div>
            </div>
            
            <div class="footer-section">
                <p class="footer-text">
                    Ready to transform your meeting experience? Let AutoMeet handle the coordination while you focus on what matters most.
                </p>
                <p class="signature">
                    Best regards,<br>
                    <strong>The AutoMeet Team</strong>
                </p>
            </div>
        </div>
        
        <div class="footer">
            <div class="footer-logo">AutoMeet</div>
            <p class="footer-disclaimer">
                This is an automated message from AutoMeet.
                Please do not reply to this email.
            </p>
        </div>
    </div>
</body>
</html>
    `;
}
