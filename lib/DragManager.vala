//  
//  Copyright (C) 2011-2012 Robert Dyer, Rico Tzschichholz
// 
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
// 
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
// 
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
// 

using Gdk;
using Gee;
using Gtk;

using Plank.Drawing;
using Plank.Factories;
using Plank.Items;
using Plank.Services.Windows;
using Plank.Widgets;

namespace Plank
{
	public class DragManager : GLib.Object
	{
		Gdk.Window proxy_window;
		
		bool drag_canceled;
		bool drag_known;
		bool drag_data_requested;
		uint marker = 0;
		uint drag_hover_timer = 0;
		Gee.Map<DockItem, int> original_item_pos = new HashMap<DockItem, int> ();
		
		DockController controller;
		
		public bool InternalDragActive { get; private set; }

		public bool HoveredAcceptsDrop { get; private set; }
		
		public ArrayList<string> drag_data;
		
		public DockItem DragItem { get; private set; }
		
		bool externalDragActive;
		public bool ExternalDragActive {
			get { return externalDragActive; }
			private set {
				if (externalDragActive == value)
					return;
				externalDragActive = value;
				
				if (!value) {
					drag_known = false;
					drag_data = null;
					drag_data_requested = false;
				}
			} 
		}
		
		bool repositionMode = false;
		public bool RepositionMode {
			get { return repositionMode; }
			private set {
				if (repositionMode == value)
					return;
				repositionMode = value;
				
				if (repositionMode)
					disable_drag_to ();
				else
					enable_drag_to ();
			}
		}
		
		public DragManager (DockController controller)
		{
			this.controller = controller;
		}
		
		public void initialize ()
		{
			controller.window.drag_motion.connect (drag_motion);
			controller.window.drag_begin.connect (drag_begin);
			controller.window.drag_data_received.connect (drag_data_received);
			controller.window.drag_data_get.connect (drag_data_get);
			controller.window.drag_drop.connect (drag_drop);
			controller.window.drag_end.connect (drag_end);
			controller.window.drag_leave.connect (drag_leave);
			controller.window.drag_failed.connect (drag_failed);
			
			controller.window.motion_notify_event.connect (window_motion_notify_event);
			
			enable_drag_to ();
			enable_drag_from ();
		}
		
		~DragManager ()
		{
			controller.window.drag_motion.disconnect (drag_motion);
			controller.window.drag_begin.disconnect (drag_begin);
			controller.window.drag_data_received.disconnect (drag_data_received);
			controller.window.drag_data_get.disconnect (drag_data_get);
			controller.window.drag_drop.disconnect (drag_drop);
			controller.window.drag_end.disconnect (drag_end);
			controller.window.drag_leave.disconnect (drag_leave);
			controller.window.drag_failed.disconnect (drag_failed);
			
			controller.window.motion_notify_event.disconnect (window_motion_notify_event);
			
			disable_drag_to ();
			disable_drag_from ();
		}
		
		bool window_motion_notify_event (Widget w, EventMotion event)
		{
			ExternalDragActive = false;
			return false;
		}
		
		void drag_data_get (Widget w, DragContext context, SelectionData selection_data, uint info, uint time_)
		{
			if (InternalDragActive && DragItem != null) {
				string uri = "%s\r\n".printf (DragItem.as_uri ());
				selection_data.set (selection_data.get_target (), 8, (uchar[]) uri.to_utf8 ());
			}
		}

		void drag_begin (Widget w, DragContext context)
		{
			controller.window.notify["HoveredItem"].connect (hovered_item_changed);
			
			// Delay persistent write of dock-preference until drag_end ()
			controller.prefs.delay ();
			
			InternalDragActive = true;
#if USE_GTK2
			keyboard_grab (controller.window.get_window (), true, get_current_event_time ());
#else
			context.get_device ().grab (controller.window.get_window (), GrabOwnership.APPLICATION, true, EventMask.ALL_EVENTS_MASK, null, get_current_event_time ());
#endif
			drag_canceled = false;
			
			if (proxy_window != null) {
				enable_drag_to ();
				proxy_window = null;
			}
			
			Pixbuf pbuf;
			DragItem = controller.window.HoveredItem;
			original_item_pos.clear ();
			
			if (RepositionMode)
				DragItem = null;
			
			if (DragItem != null) {
				foreach (DockItem item in controller.items.Items)
					original_item_pos [item] = item.Position;
				
				// FIXME
				var drag_icon_size = (int) (1.2 * controller.prefs.IconSize);
				var icon_surface = new DockSurface (drag_icon_size, drag_icon_size);
				pbuf = DragItem.get_surface_copy (drag_icon_size, drag_icon_size, icon_surface).load_to_pixbuf ();
				controller.renderer.animated_draw ();
			} else {
				pbuf = new Pixbuf (Colorspace.RGB, true, 8, 1, 1);
			}
			
			drag_set_icon_pixbuf (context, pbuf, pbuf.width / 2, pbuf.height / 2);
		}

		void drag_data_received (Widget w, DragContext context, int x, int y, SelectionData selection_data, uint info, uint time_)
		{
			if (drag_data_requested) {
				string uris = (string) selection_data.get_data ();
				
				drag_data = new ArrayList<string> ();
				foreach (string s in uris.split ("\r\n"))
					if (s.has_prefix ("file://"))
						drag_data.add (s);
				
				drag_data_requested = false;
				
				// Force initial redraw for ExternalDrag to pick up new
				// drag_data for can_accept_drop check
				controller.renderer.animated_draw ();				
			}
			
			drag_status (context, DragAction.COPY, time_);
		}

		bool drag_drop (Widget w, DragContext context, int x, int y, uint time_)
		{
			drag_finish (context, true, false, time_);
			
			if (drag_data == null)
				return true;
			
			var item = controller.window.HoveredItem;
			
			if (item != null && item.can_accept_drop (drag_data)) {
				item.accept_drop (drag_data);
			} else {
				var pos = 0;
				if (item != null)
					pos = item.Sort + 1;
				
				foreach (var uri in drag_data) {
					if (!uri.has_prefix ("file://"))
						continue;
					Factory.item_factory.make_dock_item (uri.replace ("file://", ""), pos++);
				}
			}
			
			ExternalDragActive = false;
			return true;
		}
		
		void drag_end (Widget w, DragContext context)
		{
			if (!drag_canceled && DragItem != null) {
				if (!controller.hide_manager.DockHovered) {
					if (DragItem.can_be_removed ()) {
						// Remove from dock
						controller.items.remove_item (DragItem);
						DragItem.delete ();
						
						int x, y;
#if USE_GTK2
#if VALA_0_12
						controller.window.get_display ().get_pointer (null, out x, out y, null);
#else
						ModifierType mod;
						Gdk.Screen gdk_screen;
						controller.window.get_display ().get_pointer (out gdk_screen, out x, out y, out mod);
#endif
#else
						context.get_device ().get_position (null, out x, out y);
#endif
						new PoofWindow (x, y);
					}
				} else {
					// Dropped somewhere on dock
					/* TODO
					DockItem item = controller.window.HoveredItem;
					if (item != null && item.CanAcceptDrop (DragItem))
						item.AcceptDrop (DragItem);
					*/
				}
			}
			
			InternalDragActive = false;
			DragItem = null;
#if USE_GTK2
			keyboard_ungrab (get_current_event_time ());
#else
			context.get_device ().ungrab (get_current_event_time ());
#endif
			
			controller.window.notify["HoveredItem"].disconnect (hovered_item_changed);

			// Perform persistent write of dock-preference
			controller.prefs.apply ();
			
			// Force last redraw for InternalDrag
			controller.renderer.animated_draw ();
		}

		void drag_leave (Widget w, DragContext context, uint time_)
		{
			controller.hide_manager.update_dock_hovered ();
			controller.window.update_hovered (-1, -1);
			drag_known = false;
			
			if (ExternalDragActive) {
				controller.window.notify["HoveredItem"].disconnect (hovered_item_changed);
				
				// Force last redraw for ExternalDrag
				controller.renderer.animated_draw ();
			}
			
			if (DragItem == null)
				return;
			
			if (!controller.hide_manager.DockHovered)
				reset_item_positions ();
		}
		
		bool drag_failed (Widget w, DragContext context, DragResult result)
		{
			drag_canceled = result == DragResult.USER_CANCELLED;
			
			if (drag_canceled)
				reset_item_positions ();
			
			return !drag_canceled;
		}

		bool drag_motion (Widget w, DragContext context, int x, int y, uint time_)
		{
			if (RepositionMode)
				return true;

			ExternalDragActive = !InternalDragActive;
			
			if (marker != direct_hash (context)) {
				marker = direct_hash (context);
				drag_known = false;
			}
			
			// we own the drag if InternalDragActive is true, lets not be silly
			if (ExternalDragActive && !drag_known) {
				drag_known = true;
				
				controller.window.notify["HoveredItem"].connect (hovered_item_changed);
				
				Atom atom = drag_dest_find_target (controller.window, context, drag_dest_get_target_list (controller.window));
				if (atom.name () != Atom.NONE.name ()) {
					drag_data_requested = true;
					drag_get_data (controller.window, context, atom, time_);
				} else {
					drag_status (context, DragAction.PRIVATE, time_);
				}
			} else {
				drag_status (context, DragAction.COPY, time_);
			}
			
			controller.hide_manager.update_dock_hovered ();
			controller.window.update_hovered (x, y);
			
			return true;
		}
		
		void hovered_item_changed ()
		{
			if (InternalDragActive && DragItem != null && controller.window.HoveredItem != null
				&& DragItem != controller.window.HoveredItem) {
				
				controller.items.move_item_to (DragItem, controller.window.HoveredItem);
				controller.window.serialize_item_positions ();
			}
			
			if (drag_hover_timer > 0)
				GLib.Source.remove (drag_hover_timer);
			drag_hover_timer = 0;
			
			if (ExternalDragActive && drag_data != null)
				drag_hover_timer = GLib.Timeout.add (1500, () => {
					DockItem item = controller.window.HoveredItem;
					if (item != null)
						item.scrolled (ScrollDirection.DOWN, 0);
					return item != null;
				});
		}
		
		void reset_item_positions ()
		{
			foreach (var entry in original_item_pos.entries)
				controller.items.update_item_position (entry.key, entry.value);
			
			controller.window.serialize_item_positions ();
		}
		
		Gdk.Window? best_proxy_window ()
		{
			var window_stack = controller.window.get_screen ().get_window_stack ();
			window_stack.reverse ();
			
			foreach (var window in window_stack) {
				int w_x, w_y, w_width, w_height;
				window.get_position (out w_x, out w_y);
#if USE_GTK2
				window.get_size (out w_width, out w_height);
#else
				w_width = window.get_width ();
				w_height = window.get_height ();
#endif
				var w_geo = Gdk.Rectangle () {x = w_x, y = w_y, width = w_width, height = w_height};
				
				int x, y;
#if USE_GTK2
#if VALA_0_12
				controller.window.get_display ().get_pointer (null, out x, out y, null);
#else
				ModifierType mod;
				Gdk.Screen gdk_screen;
				controller.window.get_display ().get_pointer (out gdk_screen, out x, out y, out mod);
#endif
#else
				controller.window.get_display ().get_device_manager ().get_client_pointer ().get_position (null, out x, out y);
#endif
				
#if VALA_0_12
				if (window.is_visible () && w_geo.intersect (Gdk.Rectangle () {x = x, y = y}, null))
#else
				var dest = Gdk.Rectangle ();
				if (window.is_visible () && w_geo.intersect (Gdk.Rectangle () {x = x, y = y}, dest))
#endif
					return window;
			}
			
			return null;
		}
		
		public void ensure_proxy ()
		{
			// having a proxy window here is VERY bad ju-ju
			if (InternalDragActive)
				return;
			
			if (controller.hide_manager.DockHovered) {
				if (proxy_window == null)
					return;
				proxy_window = null;
				enable_drag_to ();
				return;
			}
			
			ModifierType mod;
#if USE_GTK2
#if VALA_0_12
			controller.window.get_display ().get_pointer (null, null, null, out mod);
#else
			int x, y;
			Gdk.Screen gdk_screen;
			controller.window.get_display ().get_pointer (out gdk_screen, out x, out y, out mod);
#endif
#else
			double[] axes = {};
			controller.window.get_display ().get_device_manager ().get_client_pointer ().get_state (controller.window.get_window (), axes, out mod);
#endif
			
			if ((mod & ModifierType.BUTTON1_MASK) == ModifierType.BUTTON1_MASK) {
				Gdk.Window bestProxy = best_proxy_window ();
				if (bestProxy != null && proxy_window != bestProxy) {
					proxy_window = bestProxy;
					drag_dest_set_proxy (controller.window, proxy_window, DragProtocol.XDND, true);
				}
			}
		}

		void enable_drag_to ()
		{
#if USE_GTK2
			var te1 = TargetEntry () { target = "text/uri-list", flags = 0, info = 0 };
			var te2 = TargetEntry () { target = "text/plank-uri-list", flags = 0, info = 0 };
#else
			TargetEntry te1 = { "text/uri-list", 0, 0 };
			TargetEntry te2 = { "text/plank-uri-list", 0, 0 };
#endif
			drag_dest_set (controller.window, 0, {te1, te2}, DragAction.COPY);
		}
		
		void disable_drag_to ()
		{
			drag_dest_unset (controller.window);
		}
		
		void enable_drag_from ()
		{
			// we dont really want to offer the drag to anything, merely pretend to, so we set a mimetype nothing takes
#if USE_GTK2
			var te = TargetEntry () { target = "text/plank-uri-list", flags = TargetFlags.SAME_APP, info = 0 };
#else
			TargetEntry te = { "text/plank-uri-list", TargetFlags.SAME_APP, 0};
#endif
			drag_source_set (controller.window, ModifierType.BUTTON1_MASK, { te }, DragAction.PRIVATE);
		}
		
		void disable_drag_from ()
		{
			drag_source_unset (controller.window);
		}
	}
}
