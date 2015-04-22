Percolate Studio's fork of cordova-plugin-file-transfer
-------------------------------------------------------
We haved removed the multipart form section of the requestForUploadCommand method from the original Cordova File Transfer plugin.  
This allows the FileUpload plugin to be used when uploading to an endpoint that expects
only the raw file to be included in the body of the request, without mulitpart boundaries, for example Amazon S3.

Install like `cordova plugin add https://github.com/percolatestudio/cordova-plugin-file-upload.git`.

Usage is the same as the standard File Transfer plugin. Currently only iOS and Android supported.

## License 

MIT. (c) Percolate Studio, maintained by Tim Hingston (@timbotnik).

File Transfer was developed as part of the [Verso](versoapp.com) project.
