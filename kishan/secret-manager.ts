import { SecretManagerServiceClient } from '@google-cloud/secret-manager';

const client = new SecretManagerServiceClient();
const projectId = 'pg-ae-n-app-125609';

// 🔹 Generic function to fetch a secret
async function getSecret(name: string): Promise<string> {
    const [version] = await client.accessSecretVersion({
        name: `projects/${projectId}/secrets/${name}/versions/latest`,
    });

    return version.payload?.data?.toString() || '';
}

// 🔹 Load ALL secrets here (central place)
export async function loadSecrets() {
    const keys = [
        'CN_STAGING_DB_HOST',
    ];

    for (const key of keys) {
        try {
            process.env[key] = await getSecret(key);
            console.log(`Loaded secret: ${key} = ${process.env[key]}`);
        } catch (error) {
            console.error(`Failed to load secret: ${key}`, error);
        }
    }
}