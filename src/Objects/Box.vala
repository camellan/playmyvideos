/*-
 * Copyright (c) 2017-2018 Artem Anufrij <artem.anufrij@live.de>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 * The Noise authors hereby grant permission for non-GPL compatible
 * GStreamer plugins to be used and distributed together with GStreamer
 * and Noise. This permission is above and beyond the permissions granted
 * by the GPL license by which Noise is covered. If you modify this code
 * you may extend this exception to your version of the code, but you are not
 * obligated to do so. If you do not wish to do so, delete this exception
 * statement from your version.
 *
 * Authored by: Artem Anufrij <artem.anufrij@live.de>
 */

namespace PlayMyVideos.Objects {
    public class Box : GLib.Object {
        Services.LibraryManager library_manager;
        Services.DataBaseManager db_manager;
        Settings settings;

        public signal void video_added (Video video);
        public signal void video_removed (Video video);
        public signal void cover_changed ();
        public signal void removed ();

        public string cover_path { get; private set; default = ""; }

        int _ID = 0;
        public int ID {
            get {
                return _ID;
            } set {
                _ID = value;
                if (value > 0) {
                    this.cover_path = GLib.Path.build_filename (PlayMyVideosApp.instance.COVER_FOLDER, ("box_%d.jpg").printf (this.ID));
                    if (title == "") {
                        load_cover_async.begin ();
                    }
                }
            }
        }
        public string title { get; set; default = ""; }

        bool is_cover_loading = false;

        GLib.List<Video> _videos = null;
        public GLib.List<Video> videos {
            get {
                if (_videos == null) {
                    _videos = db_manager.get_video_collection (this);
                }
                return _videos;
            }
        }

        Gdk.Pixbuf ? _cover = null;
        public Gdk.Pixbuf ? cover {
            get {
                return _cover;
            } set {
                _cover = value;
                cover_changed ();
            }
        }

        construct {
            settings = Settings.get_default ();
            library_manager = Services.LibraryManager.instance;
            db_manager = library_manager.db_manager;
            video_removed.connect ((video) => {
                this._videos.remove (video);
                if (this.videos.length () == 0) {
                    db_manager.remove_box (this);
                }
            });
            removed.connect (() => {
                FileUtils.remove (cover_path);
            });
        }

        public Box (string title = "") {
            this.title = title;
        }

        public void add_video (Video video) {
            lock (_videos) {
                this._videos.insert_sorted_with_data (video, sort_function);
                video_added (video);
            }
        }

        public void add_video_if_not_exists (Video new_video) {
            lock (_videos) {
                foreach (var video in videos) {
                    if (video.path == new_video.path) {
                        return;
                    }
                }
                new_video.box = this;
                db_manager.insert_video (new_video);
                add_video (new_video);
            }
            load_cover_async.begin ();
        }

        private int sort_function (Video a, Video b) {
            if (a.year != b.year) {
                return a.year - b.year;
            }
            return a.title.collate (b.title);
        }

        public Video ? get_next_video (Video current) {
            int i = _videos.index (current) + 1;
            if (i < _videos.length ()) {
                return _videos.nth_data (i);
            }
            return null;
        }

        public Video ? get_first_video () {
            return this.videos.first ().data;
        }

        public void set_custom_cover_file (string uri) {
            var first_video = this.videos.first ().data;
            if (first_video != null) {
                var destination = File.new_for_uri (GLib.Path.get_dirname (first_video.uri) + "/cover.jpg");
                var source = File.new_for_path (uri);
                try {
                    source.copy (destination, GLib.FileCopyFlags.OVERWRITE);
                } catch (Error err) {
                                    warning (err.message);
                }
                destination.dispose ();
                source.dispose ();
            }
        }

// COVER REGION
        public async void load_cover_async () {
            if (is_cover_loading || _cover != null || ID == 0 || videos.length () == 0) {
                return;
            }
            is_cover_loading = true;
            load_or_create_cover.begin (
                (obj, res) => {
                    Gdk.Pixbuf ? return_value = load_or_create_cover.end (res);
                    if (return_value != null) {
                        cover = return_value;
                    } else if (settings.load_content_from_moviedb) {
                        Services.MovieDatabaseManager.instance.fill_box_cover_queue (this);
                    }
                    is_cover_loading = false;
                });
        }

        private async Gdk.Pixbuf ? load_or_create_cover () {
            SourceFunc callback = load_or_create_cover.callback;

            Gdk.Pixbuf ? return_value = null;
            new Thread<void*> (
                "load_or_create_cover",
                () => {
                    if (FileUtils.test (cover_path, FileTest.EXISTS)) {
                        try {
                            return_value = new Gdk.Pixbuf.from_file (cover_path);
                            Idle.add ((owned) callback);
                            return null;
                        } catch (Error err) {
                                    warning (err.message);
                        }
                    }

                    string[] cover_files = PlayMyVideos.Settings.get_default ().covers;

                    foreach (var video in videos) {
                        var dir_name = GLib.Path.get_dirname (video.path);
                        foreach (var cover_file in cover_files) {
                            var cover_path = GLib.Path.build_filename (dir_name, cover_file);
                            if (FileUtils.test (cover_path, FileTest.EXISTS)) {
                                try {
                                    return_value = save_cover (new Gdk.Pixbuf.from_file (cover_path));
                                    Idle.add ((owned) callback);
                                    return null;
                                } catch (Error err) {
                                    warning (err.message);
                                }
                            }
                        }

                        var cover_path = GLib.Path.build_filename (dir_name, video.box.title + ".jpg");
                        if (FileUtils.test (cover_path, FileTest.EXISTS)) {
                            try {
                                return_value = save_cover (new Gdk.Pixbuf.from_file (cover_path));
                                Idle.add ((owned) callback);
                                return null;
                            } catch (Error err) {
                                    warning (err.message);
                            }
                        }

                        cover_path = GLib.Path.build_filename (dir_name, video.title + ".jpg");
                        if (FileUtils.test (cover_path, FileTest.EXISTS)) {
                            try {
                                return_value = save_cover (new Gdk.Pixbuf.from_file (cover_path));
                                Idle.add ((owned) callback);
                                return null;
                            } catch (Error err) {
                                    warning (err.message);
                            }
                        }

                        cover_path = video.path + ".jpg";
                        if (FileUtils.test (cover_path, FileTest.EXISTS)) {
                            try {
                                return_value = save_cover (new Gdk.Pixbuf.from_file (cover_path));
                                Idle.add ((owned) callback);
                                return null;
                            } catch (Error err) {
                                    warning (err.message);
                            }
                        }
                    }
                    Idle.add ((owned) callback);
                    return null;
                });
            yield;
            return return_value;
        }

        public void set_new_cover (Gdk.Pixbuf cover) {
            this.cover = save_cover (cover);
        }

        protected Gdk.Pixbuf ? save_cover (Gdk.Pixbuf p) {
            Gdk.Pixbuf ? pixbuf = Utils.align_and_scale_pixbuf_for_cover (p);
            try {
                pixbuf.save (cover_path, "jpeg", "quality", "100");
            } catch (Error err) {
                                    warning (err.message);
            }
            return pixbuf;
        }
    }
}
