package starling.core {

	import flash.display.Graphics;
	import flash.display.Shape;

	import starling.display.BlendMode;

	public class OverlayDraw extends Shape {

		private static var collector:OverlayDraw;

		public static function create(alpha:Number = 1, blendMode:String = null):OverlayDraw {
			var current:OverlayDraw = collector;
			if (current == null) {
				current = new OverlayDraw();
				if (alpha != 1) current.alpha = alpha;
				if (blendMode != null && blendMode != BlendMode.NORMAL) current.blendMode = blendMode;
			} else {
				current.alpha = alpha;
				if (blendMode != null) current.blendMode = blendMode;
				else current.blendMode = flash.display.BlendMode.NORMAL;
				current.gfx.clear();
				collector = collector.next;
			}
			return current;
		}

		public static function destroy(element:OverlayDraw):void {
			element.next = collector;
			collector = element;
		}

		public var next:OverlayDraw;

		public var gfx:Graphics;

		public function OverlayDraw() {
			gfx = graphics;
		}

	}
}
