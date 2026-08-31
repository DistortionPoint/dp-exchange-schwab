# App Callback URL Requirements and Limitations

Source: https://developer.schwab.com/user-guides/apis-and-apps/app-callback-url-requirements
Captured: 2026-08-31 from the signed-in Schwab Developer Portal.

---

What are the requirements for the Callback URL (redirect_uri)?

What errors are associated with Callback URLs?

A Callback URL (“redirect_uri” parameter) is required when creating an App on the Developer Portal. This URL will be utilized in the OAuth //authorize step to redirect the User from LMS, for “consent and grant,” back to the calling App.

Per OAuth 2 requirements, a Callback URL is only applicable for the “authorization_code” and implicit flows (“grant_type”). Currently, the only available OAuth flow for Schwab APIs is the “authorization_code” Grant Type.

Callback URL Requirements and Recommendations:

Callback URL requirements are configured by each Line of Business and may vary depending on the API Product being offered.

URL Scheme: Some LOBs require the Callback URL scheme to be secure (HTTPS). While other support HTTP or other URL schemes depending on specific business requirements.
All callback URLS will be validated to ensure it meets basic URL structure.
All callback URLS will be validated to ensure there are no special or unsupported characters in the address.

If no Callback URL is sent during the OAuth flow, the value will automatically default to the Callback URL registered when the App was created on Schwab’s Dev Portal.

In this scenario, if multiple Callback URLs were registered with the App, an error may be returned. The reason being the inability to determine which one use since none was specified in the API request.
The Callback URL sent during the OAuth flow must be identical to one of the Callback URL(s) registered with the App being used.

Note:

The table below will highlight some common permutations and the associated error reason information.

Adding Multiple Callback URLs for a single App

Multiple URLS are supported for a single app. This can be done on either on the Create App form or the Modify App forms.

To add multiple Callback URLS:

Enter Callback URLs by separating each with a comma. NOTE do not separate the comma and the next URL with a Space.

example https://www.example.com/path/page.etc, https://www.example.com/path2/page.etc

The field is currently limited at 256 characters max.

Contact support if a special use-cases occurs that exceed this limitation.

Common Callback URL Errors and Reasons:

Registered URL

	

URL Sent in OAuth //authorize

	

Response or Error

https://host/path

	

https://host/path

	

Successful response

https://host/path

	

myapp://blah/bam

	

Error - invalid URI specified

Reason: scheme sent does not match registered

myapp://blah/bam

	

https://host/path

	

Error - invalid URI specified

Reason: scheme sent does not match registered

https://host/path

	

http://host/path

	

Error - invalid URI specified

Reason: scheme sent does not match registered

(“https” vs. “http”)

myapp://this/that

	

myapp://host/path

	

Error - invalid URI specified

Reason: path sent does not match registered

myapp://this/that

	

myapp://this/that

	

Successful response
