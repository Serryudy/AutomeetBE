# Automeet
AutoMeet is an open-source scheduling tool inspired by platforms like Chili Piper, designed to simplify meeting bookings, lead conversion, and calendar synchronization for teams and businesses. Built with a Ballerina backend, AutoMeet offers flexibility, customizability, and integrations with popular tools such as Zoom, Google Meet, and Google Calendar. This project aims to provide a fully open-source, robust meeting automation solution with AI-enhanced scheduling suggestions, customizable UI, and seamless video conferencing integration.

Features
1. Instant Meeting Booking
Schedule meetings instantly via email, chat, or web forms.
Prospective clients and team members can see real-time availability to self-schedule without back-and-forth communication.
2. Automated Email and SMS Reminders
Reduces no-shows with automated email and SMS reminders for all participants, helping ensure meeting attendance.
3. Rescheduling and Cancellations
Allows users to reschedule or cancel meetings easily, with automatic notifications sent to attendees for clear communication.
4. Real-Time Calendar Syncing
Syncs with Google Calendar and Microsoft Outlook to reflect real-time availability, avoiding double-booking.
5. Customizable Meeting Templates
Offers templates with configurable options for meeting titles, participant details, and video conferencing links (Zoom, Google Meet), ensuring consistency.
6. Round-Robin Scheduling
Uses round-robin logic to distribute meetings across team members based on availability, ensuring fair and efficient resource usage.
7. AI-Driven Scheduling Suggestions
AutoMeet's backend leverages AI to suggest the most suitable meeting times, using factors like user availability patterns, priority levels, and historical booking data.
8. Customizable User Interface
Provides a flexible UI where colors, fonts, and layouts can be tailored to match brand standards, and users can adjust their view preferences for better usability.
9. Video Conferencing Integration
Automatically generates Zoom or Google Meet links, including them in meeting invites for seamless virtual meeting setup.
10. In-Depth Analytics Dashboard
Displays key metrics like meeting frequency, attendance, and team member availability, giving managers insights to make data-driven decisions.
Tech Stack
Backend: Ballerina
Ballerina is a cloud-native programming language ideal for integration and backend development. In AutoMeet, Ballerina manages calendar, email, SMS, and video conferencing API integrations, delivering a scalable, reliable backend that’s easy to modify.
The Ballerina backend is responsible for:
Handling scheduling logic, including round-robin and AI-driven recommendations.
Managing secure API connections to external services such as Google Calendar, Zoom, and Google Meet.
Performing real-time data handling for instant calendar updates and availability checks.
Providing an API for frontend and mobile applications, ensuring a clean separation between UI and backend logic.
Frontend
React.js for a dynamic and customizable UI.
The UI components are fully adjustable, allowing teams to create branded interfaces and provide a better user experience.
Database
MongoDB: Stores user profiles, scheduling data, and meeting history. MongoDB’s flexibility makes it easy to handle complex meeting data and logs.
Machine Learning
An AI component for optimal time slot recommendations is embedded within the Ballerina backend.
The AI model uses historical data to refine its suggestions, improving as more bookings are processed.
Third-Party Integrations
Google Calendar and Outlook Calendar for calendar syncing.
Zoom and Google Meet APIs for automatic video link generation.
Twilio or similar services for SMS notifications.
SendGrid or SMTP for email reminders.
User Roles
Admin User
Has access to manage meeting slots, add new templates, and view detailed analytics.
Can customize UI settings and brand the platform’s look for a cohesive experience.
Receives AI-driven insights to optimize scheduling efficiency.
End User
Can select available slots and receive AI recommendations for suitable times.
Can reschedule, cancel, or add participants to booked meetings.
Uses a simple, responsive interface with branded elements for seamless interaction.
Installation and Setup
Prerequisites
Ballerina: Install Ballerina for backend services.
MongoDB: Ensure MongoDB is installed and running.
Node.js and npm: Install Node.js and npm for the React frontend.
API Keys: Obtain API keys for Google Calendar, Zoom, Google Meet, and Twilio (or your preferred SMS service).
Backend Setup (Ballerina)
Clone the repository.
bash
Copy code
git clone https://github.com/your-repo/AutoMeet.git
cd AutoMeet
Set up configuration files for API keys and database connections.
Start the backend server with Ballerina.
bash
Copy code
bal run backend/
Frontend Setup
Navigate to the frontend directory and install dependencies.
bash
Copy code
cd frontend
npm install
Run the React application.
bash
Copy code
npm start
Usage
Admin Panel: Admins can set up meeting slots, create templates, and configure UI branding.
Meeting Scheduling: Users can view available slots, book meetings, reschedule, and access AI-suggested time slots.
Real-Time Sync: Calendar updates and availability are synced instantly across connected calendars, with reminders sent via email or SMS.
Contributing
We welcome contributions! Please submit pull requests or report issues to help improve AutoMeet.

Future Enhancements
Advanced Lead Scoring: Implement AI-based lead scoring to prioritize meetings with high-potential clients.
Multi-Language Support: Enable global teams to use AutoMeet in multiple languages.
CRM Integrations: Integrate with popular CRMs for improved lead tracking and conversion analysis.
License
AutoMeet is licensed under the MIT License. See LICENSE for more information.
