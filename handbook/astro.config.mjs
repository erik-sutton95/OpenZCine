// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// Local preview is the site root. opencapture.org serves the handbook under
// /openzcine/docs/: that build sets HANDBOOK_BASE=/openzcine/docs.
const handbookBase = process.env.HANDBOOK_BASE || '/';

export default defineConfig({
  site: 'https://opencapture.org',
  base: handbookBase,
  trailingSlash: 'always',
  integrations: [
    starlight({
      title: 'OpenZCine',
      description:
        'OpenZCine docs: Nikon Z protocol, iOS and Android apps, and how to build.',
      logo: {
        src: './src/assets/icon.png',
        alt: 'OpenZCine',
      },
      favicon: 'favicon.png',
      customCss: ['./src/styles/theme.css'],
      editLink: {
        baseUrl: 'https://github.com/erik-sutton95/OpenZCine/edit/main/handbook/',
      },
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/erik-sutton95/OpenZCine',
        },
      ],
      sidebar: [
        {
          label: 'Getting started',
          items: [
            { label: 'Overview', slug: '' },
            { label: 'Setup and build', slug: 'guides/setup' },
            { label: 'Troubleshooting', slug: 'guides/troubleshooting' },
          ],
        },
        {
          label: 'Apps',
          items: [
            { label: 'iOS', slug: 'apps/ios' },
            { label: 'Android', slug: 'apps/android' },
            { label: 'Share This Feed', slug: 'guides/share-feed' },
          ],
        },
        {
          label: 'Nikon Z Devices',
          items: [
            { label: 'Device references', slug: 'devices' },
            {
              label: 'Nikon ZR', collapsed: true,
              items: [
                { label: 'Overview and evidence', slug: 'devices/zr' },
                { label: 'Command comparison', slug: 'devices/zr/commands' },
                { label: 'Shooting modes and formats', slug: 'devices/zr/modes' },
                { label: 'Exposure, focus and audio', slug: 'devices/zr/settings' },
                { label: 'Focus drive and capture controls', slug: 'devices/zr/controls' },
                { label: 'Original media', slug: 'devices/zr/media' },
                { label: 'Connection and reconnect', slug: 'devices/zr/connection' },
                { label: 'Coverage and implementation', slug: 'devices/zr/coverage' },
              ],
            },
            {
              label: 'Nikon Z 6III', collapsed: true,
              items: [
                { label: 'Overview and evidence', slug: 'devices/z6iii' },
                { label: 'Connection and reconnect', slug: 'devices/z6iii/connection' },
                { label: 'Coverage and implementation', slug: 'devices/z6iii/coverage' },
              ],
            },
            {
              label: 'Original Z 5, Z 6, Z 7 and Z 50', collapsed: true,
              items: [
                { label: 'Overview and evidence', slug: 'devices/gen-1' },
                { label: 'Connection and reconnect', slug: 'devices/gen-1/connection' },
              ],
            },
          ],
        },
        {
          label: 'Shared protocol',
          items: [
            { label: 'Connection spine', slug: 'protocol/connection' },
            { label: 'Camera Wi-Fi', slug: 'protocol/wifi' },
            { label: 'PTP-IP packet', slug: 'protocol/ptpip-packet' },
            { label: 'PTP-IP and USB transport', slug: 'protocol/ptpip-transport' },
            { label: 'Command catalog', slug: 'protocol/commands' },
            { label: 'Live view', slug: 'protocol/live-view' },
            { label: 'Media transfer', slug: 'protocol/media' },
            { label: 'iOS notes', slug: 'protocol/ios' },
          ],
        },
        {
          label: 'Development',
          items: [
            { label: 'Architecture', slug: 'apps/architecture' },
            { label: 'Keeping docs current', slug: 'contribute/documentation' },
          ],
        },
        {
          label: 'Release notes',
          items: [
            { label: '0.2.5', slug: 'releases/0-2-5' },
          ],
        },
      ],
    }),
  ],
});
