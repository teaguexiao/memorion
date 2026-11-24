# Developer setup

## API server

The API uses Python 3.11. Set up a Firebase project with Authentication and Firestore, a Redis instance, and credentials for the speech-to-text and language model providers you want to use. Keep service account files and provider keys outside the checkout. Use a Firebase project dedicated to development.

Copy the environment template and set your project, credentials, Redis connection and provider settings. Inside a container, set the Redis host to an address reachable from that container. Mount service account files read-only and set `GOOGLE_APPLICATION_CREDENTIALS` to the path inside the container. `SERVICE_ACCOUNT_JSON` is an alternative for deployments with a secret manager.

```sh
cd backend
cp .env.template .env
docker build -t memorion-api-dev .
docker run --rm --env-file .env -p 127.0.0.1:8000:8080 memorion-api-dev
```

Add any required service account mount to the run command. The health endpoint is `http://127.0.0.1:8000/health_check` and the API schema is at `http://127.0.0.1:8000/docs`.

For a native setup, install FFmpeg, libopus, libogg and libsndfile, then install the Python dependencies in an isolated environment. The Dockerfile shows the pinned dependency set. Start the API with `uvicorn main:app --env-file .env --host 127.0.0.1 --port 8000` from `backend/`.

To use the mobile app against your instance, create a developer tenant in your own Firestore project. In the configured backend environment, the following command prints the generated developer ID. Add it to `MEMORION_APP_DEVELOPER_ID` and restart the API before signing in from the app.

```sh
python -c 'from database.developers import create_developer; print(create_developer("maintainer@example.org", name="Local Memorion").id)'
```

Configure the storage buckets, embedding index and optional integrations for the features you plan to use. Review retention and provider settings before recording personal data.

### Optional speaker matching service

Set `SPEECH_PROFILE_SERVICE_TOKEN` to the same secret in the API server and in the Modal function environment. Configure the relevant HTTPS endpoints from your own deployment using `HOSTED_SPEECH_PROFILE_API_URL`, `MODAL_SPEECH_PROFILE_WITH_UPLOAD_URL` and `CAMPPLUS_EMBED_URL`. The API sends the token in the `X-Speech-Profile-Token` header. The normal matching path passes authorized profile audio to the service. Legacy lookup by user ID is disabled by default.

## Mobile app

Use the Flutter version in [`app/.fvmrc`](../app/.fvmrc). Install Xcode and CocoaPods for Apple platforms or the Android SDK and JDK for Android.

```sh
cd app
cp .env.template .dev.env
cp .env.template .env
flutter pub get
dart run build_runner build --delete-conflicting-outputs
```

Set `API_BASE_URL` in the flavor’s env file to your API. The standard Android emulator can reach a service running on the host at `10.0.2.2`. For a physical device, use a reachable HTTPS development URL.

- Register your application IDs in your Firebase project and enable the sign-in providers you use.
- On iOS, place your Firebase plist at `app/ios/Config/Dev/GoogleService-Info.plist`. Set `GOOGLE_REVERSE_CLIENT_ID` in `app/ios/Flutter/Local.xcconfig` for Google sign-in. Set your signing team, app and Watch bundle identifiers, and associated capabilities in Xcode for device builds.
- On Android, place the Firebase configuration at `app/android/app/src/dev/google-services.json`. Register the signing fingerprints needed by your sign-in providers.
- For `prod`, use `Config/Prod` on iOS and `app/src/prod` under the Android project, with equivalent configuration and signing for your application IDs.

Run `flutter run --flavor dev` for a configured app. The app exchanges a Firebase ID token for a user-bound API key after sign-in. If a previous build saved a manually configured key in the old credentials slot, configure it again in the new build. Widget tests can run with the template env files and generated code.

## CLI and MCP

Use Node.js 22 for the TypeScript workspaces. From [`cli/`](../cli/README.md), run `npm ci`, `npm run build` and `npm test`.

For a self-hosted instance, set the following variables in the CLI environment or in the environment of your MCP client. Obtain the key and user ID from your own instance.

```sh
export MEMORION_BASE_URL=http://127.0.0.1:8000
export MEMORION_API_KEY='<key from your instance>'
export MEMORION_USER_ID='<external_user_id>'
memorion whoami
```

For interactive CLI login with an API key, run `memorion login --with-key --base-url http://127.0.0.1:8000`. To persist the URL for future commands, set it with `memorion config set base-url http://127.0.0.1:8000` before logging in. The source builds of the CLI and MCP default to `http://127.0.0.1:8000`. For browser login, pass the URL of a compatible consent page with `--auth-url` or set `MEMORION_AUTH_URL`.

See the [MCP client setup](../cli/packages/mcp/README.md) for stdio and authenticated HTTP configuration.

See the [Developer API quick start](api/README.md) and [firmware project index](../firmware/README.md).
