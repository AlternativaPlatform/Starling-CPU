package starling.core {

	import flash.display.BlendMode;
	import flash.display.Shape;
	import flash.display.Sprite;

	public class NativeOverlay extends Sprite {

		private var mDrawCount:int = 0;

		public function NativeOverlay() {
		}

		public function resetDraws():void {
			mDrawCount = 0;
		}

		public function nextDraw(alpha:Number = 1.0, blendMode:String = null):Shape {
			var current:OverlayDraw = mDrawCount < this.numChildren ? OverlayDraw(this.getChildAt(mDrawCount)) : null;
			if (current == null) {
				current = OverlayDraw.create(alpha, blendMode);
				this.addChild(current);
			} else {
				current.graphics.clear();
				current.alpha = alpha;
				if (blendMode != null) current.blendMode = blendMode; else current.blendMode = BlendMode.NORMAL;
			}
			mDrawCount++;
			return current;
		}

		public function finishDraws():void {
			for (var i:int = this.numChildren - 1; i >= mDrawCount; i--) {
				OverlayDraw.destroy(OverlayDraw(this.removeChildAt(i)));
			}
		}

	}
}
